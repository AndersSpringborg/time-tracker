package api

import (
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"time-tracker/internal/application/contracts"
	"time-tracker/internal/domain"
)

const (
	tidsregSessionCookieName = "tt_tidsreg_session"
	tidsregSessionTTL        = 15 * time.Minute
)

type tidsregSessionData struct {
	Cookie    string
	Mode      domain.TidsregMode
	Customers []domain.TidsregCustomer
	Preview   *domain.TidsregImportPreview
	ExpiresAt time.Time
}

type tidsregSessionStore struct {
	mu    sync.Mutex
	items map[string]tidsregSessionData
}

func newTidsregSessionStore() *tidsregSessionStore {
	return &tidsregSessionStore{items: map[string]tidsregSessionData{}}
}

func (s *tidsregSessionStore) create(data tidsregSessionData) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.pruneLocked(time.Now())
	id := randomID()
	data.ExpiresAt = time.Now().Add(tidsregSessionTTL)
	s.items[id] = data
	return id
}

func (s *tidsregSessionStore) get(id string) (tidsregSessionData, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	item, ok := s.items[id]
	if !ok {
		return tidsregSessionData{}, false
	}
	if time.Now().After(item.ExpiresAt) {
		delete(s.items, id)
		return tidsregSessionData{}, false
	}
	item.ExpiresAt = time.Now().Add(tidsregSessionTTL)
	s.items[id] = item
	return item, true
}

func (s *tidsregSessionStore) update(id string, item tidsregSessionData) {
	s.mu.Lock()
	defer s.mu.Unlock()
	item.ExpiresAt = time.Now().Add(tidsregSessionTTL)
	s.items[id] = item
}

func (s *tidsregSessionStore) delete(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.items, id)
}

func (s *tidsregSessionStore) pruneLocked(now time.Time) {
	for id, item := range s.items {
		if now.After(item.ExpiresAt) {
			delete(s.items, id)
		}
	}
}

func randomID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 10)
	}
	return hex.EncodeToString(b)
}

func (s *Server) handleTidsregPage(w http.ResponseWriter, r *http.Request) {
	s.render(w, "layout", pageData{Title: "Integrations", Page: "integrations_tidsreg", Body: "integrations_tidsreg", TidsregMode: "0"})
}

func (s *Server) handleTidsregLoginPartial(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.NotFound(w, r)
		return
	}
	s.render(w, "partials/tidsreg_login", pageData{TidsregMode: "0"})
}

func (s *Server) handleTidsregSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if s.app.Tidsreg == nil {
		http.Error(w, "tidsreg usecase is not configured", 500)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", 400)
		return
	}

	modeRaw := strings.TrimSpace(r.Form.Get("mode"))
	mode := domain.ParseTidsregMode(modeRaw)
	username := strings.TrimSpace(r.Form.Get("username"))
	password := r.Form.Get("password")

	authRes, err := s.app.Tidsreg.AuthenticateAndListCustomers(r.Context(), contracts.TidsregAuthenticateRequest{
		Username: username,
		Password: password,
		Mode:     mode,
	})
	if err != nil {
		s.render(w, "partials/tidsreg_login", pageData{TidsregError: err.Error(), TidsregMode: strconv.Itoa(int(mode))})
		return
	}
	cookie := authRes.SessionCookie
	customers := authRes.Customers

	sessionID := s.tidsregSession.create(tidsregSessionData{
		Cookie:    cookie,
		Mode:      mode,
		Customers: customers,
	})
	http.SetCookie(w, &http.Cookie{
		Name:     tidsregSessionCookieName,
		Value:    sessionID,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	})

	s.render(w, "partials/tidsreg_customers", pageData{TidsregCustomers: customers, TidsregMode: strconv.Itoa(int(mode))})
}

func (s *Server) handleTidsregSessionClear(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if cookie, err := r.Cookie(tidsregSessionCookieName); err == nil {
		s.tidsregSession.delete(cookie.Value)
	}
	http.SetCookie(w, &http.Cookie{Name: tidsregSessionCookieName, Value: "", Path: "/", Expires: time.Unix(0, 0), MaxAge: -1, HttpOnly: true, SameSite: http.SameSiteLaxMode})
	s.render(w, "partials/tidsreg_login", pageData{TidsregMode: "0"})
}

func (s *Server) handleTidsregPreview(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if s.app.Tidsreg == nil {
		http.Error(w, "tidsreg usecase is not configured", 500)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", 400)
		return
	}
	sessionID, session, ok := s.requireTidsregSession(r)
	if !ok {
		s.render(w, "partials/tidsreg_login", pageData{TidsregError: "Session expired. Please log in again.", TidsregMode: "0"})
		return
	}

	selectedCustomers, err := parseInt64Values(r.Form["customer_ids"])
	if err != nil {
		s.render(w, "partials/tidsreg_customers", pageData{TidsregCustomers: session.Customers, TidsregError: "Invalid customer selection", TidsregMode: strconv.Itoa(int(session.Mode))})
		return
	}

	previewRes, err := s.app.Tidsreg.BuildPreview(r.Context(), contracts.TidsregBuildPreviewRequest{
		SessionCookie:       session.Cookie,
		Mode:                session.Mode,
		Customers:           session.Customers,
		SelectedCustomerIDs: selectedCustomers,
	})
	if err != nil {
		s.render(w, "partials/tidsreg_customers", pageData{TidsregCustomers: session.Customers, TidsregError: err.Error(), TidsregMode: strconv.Itoa(int(session.Mode))})
		return
	}
	preview := previewRes.Preview
	session.Preview = &preview
	s.tidsregSession.update(sessionID, session)
	s.render(w, "partials/tidsreg_preview", pageData{TidsregPreview: preview, TidsregMode: strconv.Itoa(int(session.Mode))})
}

func (s *Server) handleTidsregImport(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if s.app.Tidsreg == nil {
		http.Error(w, "tidsreg usecase is not configured", 500)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form", 400)
		return
	}
	sessionID, session, ok := s.requireTidsregSession(r)
	if !ok || session.Preview == nil {
		s.render(w, "partials/tidsreg_login", pageData{TidsregError: "Session expired. Please log in again.", TidsregMode: "0"})
		return
	}

	commitRes, err := s.app.Tidsreg.Commit(r.Context(), contracts.TidsregCommitRequest{
		Preview:      *session.Preview,
		SelectedKeys: r.Form["candidate_keys"],
	})
	if err != nil {
		s.render(w, "partials/tidsreg_preview", pageData{TidsregPreview: *session.Preview, TidsregError: err.Error(), TidsregMode: strconv.Itoa(int(session.Mode))})
		return
	}
	result := commitRes.Result

	s.tidsregSession.delete(sessionID)
	http.SetCookie(w, &http.Cookie{Name: tidsregSessionCookieName, Value: "", Path: "/", Expires: time.Unix(0, 0), MaxAge: -1, HttpOnly: true, SameSite: http.SameSiteLaxMode})
	summary := "Imported " + strconv.Itoa(result.ImportedCandidates) + " project phases"
	s.render(w, "partials/tidsreg_result", pageData{TidsregResult: result, TidsregSummary: summary, TidsregMode: "0"})
}

func (s *Server) requireTidsregSession(r *http.Request) (string, tidsregSessionData, bool) {
	cookie, err := r.Cookie(tidsregSessionCookieName)
	if err != nil {
		return "", tidsregSessionData{}, false
	}
	session, ok := s.tidsregSession.get(cookie.Value)
	if !ok {
		return "", tidsregSessionData{}, false
	}
	return cookie.Value, session, true
}

func parseInt64Values(values []string) ([]int64, error) {
	out := make([]int64, 0, len(values))
	for _, raw := range values {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		v, err := strconv.ParseInt(raw, 10, 64)
		if err != nil {
			return nil, err
		}
		if v > 0 {
			out = append(out, v)
		}
	}
	return out, nil
}
