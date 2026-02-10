package domain

import "errors"

var (
	ErrProjectTitleRequired  = errors.New("project title is required")
	ErrProjectTitleConflict  = errors.New("project title already exists")
	ErrProjectNotFound       = errors.New("project not found")
	ErrActivityTitleRequired = errors.New("activity title is required")
	ErrActivityTitleConflict = errors.New("activity title already exists in project")
	ErrActivityNotFound      = errors.New("activity not found")
	ErrActivityInUse         = errors.New("activity is in use")
)
