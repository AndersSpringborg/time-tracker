package tidsreg

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"

	"time-tracker/internal/domain"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func newTestClient(fn roundTripFunc) *Client {
	httpClient := &http.Client{Transport: fn}
	return NewForTest(httpClient, "https://tidsreg.example")
}

func response(status int, headers map[string][]string, body string) *http.Response {
	h := make(http.Header, len(headers))
	for k, v := range headers {
		h[k] = append([]string(nil), v...)
	}
	return &http.Response{
		StatusCode: status,
		Header:     h,
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}

func TestAuthenticateCombinesSetCookieHeaders(t *testing.T) {
	c := newTestClient(func(r *http.Request) (*http.Response, error) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/auth/login" {
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		return response(http.StatusOK, map[string][]string{
			"Set-Cookie": {"a=1; Path=/", "b=2; Path=/"},
		}, "ok"), nil
	})

	cookie, err := c.Authenticate(context.Background(), "u", "p")
	if err != nil {
		t.Fatalf("Authenticate failed: %v", err)
	}
	if cookie != "a=1; b=2" {
		t.Fatalf("unexpected cookie string: %s", cookie)
	}
}

func TestListCustomersUsesModeAndCookie(t *testing.T) {
	c := newTestClient(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/Find/SelectCustomers" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		if r.URL.Query().Get("mode") != "0" {
			t.Fatalf("unexpected mode: %s", r.URL.Query().Get("mode"))
		}
		if got := r.Header.Get("Cookie"); !strings.Contains(got, "session=abc") {
			t.Fatalf("missing cookie, got %q", got)
		}
		return response(http.StatusOK, map[string][]string{"Content-Type": {"application/json"}}, `[{"CustomerId":1,"Name":"Trifork"}]`), nil
	})

	customers, err := c.ListCustomers(context.Background(), "session=abc", domain.TidsregModeTime)
	if err != nil {
		t.Fatalf("ListCustomers failed: %v", err)
	}
	if len(customers) != 1 || customers[0].Name != "Trifork" {
		t.Fatalf("unexpected customers: %+v", customers)
	}
}
