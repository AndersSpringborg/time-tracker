package tidsreg

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	tidsregmodel "time-tracker/internal/application/integrations/tidsreg"
)

type Client struct {
	httpClient *http.Client
	baseURL    string
}

func New() *Client {
	return &Client{
		httpClient: &http.Client{Timeout: 20 * time.Second},
		baseURL:    "https://tidsreg.trifork.com",
	}
}

func NewForTest(httpClient *http.Client, baseURL string) *Client {
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 20 * time.Second}
	}
	return &Client{httpClient: httpClient, baseURL: strings.TrimRight(baseURL, "/")}
}

func (c *Client) Authenticate(ctx context.Context, username, password string) (string, error) {
	payload := url.Values{}
	payload.Set("username", username)
	payload.Set("password", password)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/api/auth/login", strings.NewReader(payload.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	res, err := c.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()

	if res.StatusCode < 200 || res.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(res.Body, 1024))
		return "", fmt.Errorf("tidsreg auth failed: status=%d body=%q", res.StatusCode, strings.TrimSpace(string(b)))
	}

	setCookies := res.Header.Values("Set-Cookie")
	parts := make([]string, 0, len(setCookies))
	for _, cookie := range setCookies {
		if idx := strings.Index(cookie, ";"); idx > 0 {
			parts = append(parts, cookie[:idx])
		} else if strings.TrimSpace(cookie) != "" {
			parts = append(parts, cookie)
		}
	}
	if len(parts) == 0 {
		return "", fmt.Errorf("tidsreg auth failed: no session cookie returned")
	}
	return strings.Join(parts, "; "), nil
}

func (c *Client) ListCustomers(ctx context.Context, sessionCookie string, mode tidsregmodel.Mode) ([]tidsregmodel.Customer, error) {
	var payload []struct {
		CustomerID int64  `json:"CustomerId"`
		Name       string `json:"Name"`
	}
	if err := c.getJSON(ctx, sessionCookie, "/Find/SelectCustomers?mode="+strconv.Itoa(int(mode)), &payload); err != nil {
		return nil, err
	}
	out := make([]tidsregmodel.Customer, 0, len(payload))
	for _, item := range payload {
		out = append(out, tidsregmodel.Customer{CustomerID: item.CustomerID, Name: item.Name})
	}
	return out, nil
}

func (c *Client) ListProjects(ctx context.Context, sessionCookie string, customerID int64, mode tidsregmodel.Mode) ([]tidsregmodel.Project, error) {
	var payload []struct {
		ProjectID int64  `json:"ProjectId"`
		Name      string `json:"Name"`
	}
	path := fmt.Sprintf("/Find/SelectProjects?mode=%d&customerId=%d", mode, customerID)
	if err := c.getJSON(ctx, sessionCookie, path, &payload); err != nil {
		return nil, err
	}
	out := make([]tidsregmodel.Project, 0, len(payload))
	for _, item := range payload {
		out = append(out, tidsregmodel.Project{ProjectID: item.ProjectID, CustomerID: customerID, Name: item.Name})
	}
	return out, nil
}

func (c *Client) ListPhases(ctx context.Context, sessionCookie string, projectID int64, mode tidsregmodel.Mode) ([]tidsregmodel.Phase, error) {
	var payload []struct {
		PhaseID int64  `json:"PhaseId"`
		Name    string `json:"Name"`
	}
	path := fmt.Sprintf("/Find/SelectPhases?mode=%d&projectId=%d", mode, projectID)
	if err := c.getJSON(ctx, sessionCookie, path, &payload); err != nil {
		return nil, err
	}
	out := make([]tidsregmodel.Phase, 0, len(payload))
	for _, item := range payload {
		out = append(out, tidsregmodel.Phase{PhaseID: item.PhaseID, ProjectID: projectID, Name: item.Name})
	}
	return out, nil
}

func (c *Client) ListActivities(ctx context.Context, sessionCookie string, phaseID int64, mode tidsregmodel.Mode) ([]tidsregmodel.Activity, error) {
	var payload []struct {
		ActivityID int64  `json:"ActivityId"`
		Name       string `json:"Name"`
	}
	path := fmt.Sprintf("/Find/SelectActivities?mode=%d&phaseId=%d", mode, phaseID)
	if err := c.getJSON(ctx, sessionCookie, path, &payload); err != nil {
		return nil, err
	}
	out := make([]tidsregmodel.Activity, 0, len(payload))
	for _, item := range payload {
		out = append(out, tidsregmodel.Activity{ActivityID: item.ActivityID, PhaseID: phaseID, Name: item.Name})
	}
	return out, nil
}

func (c *Client) getJSON(ctx context.Context, sessionCookie, path string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Cookie", sessionCookie)
	req.Header.Set("Accept", "*/*")
	req.Header.Set("Referer", c.baseURL+"/Voucher")
	req.Header.Set("X-Requested-With", "XMLHttpRequest")
	req.Header.Set("User-Agent", "time-tracker/1.0")

	res, err := c.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()

	body, err := io.ReadAll(res.Body)
	if err != nil {
		return err
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return fmt.Errorf("tidsreg request failed: path=%s status=%d body=%q", path, res.StatusCode, strings.TrimSpace(string(body)))
	}
	if err := json.Unmarshal(body, out); err != nil {
		return fmt.Errorf("decode tidsreg response %s: %w", path, err)
	}
	return nil
}
