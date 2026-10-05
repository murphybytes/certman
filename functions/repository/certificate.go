package repository

import (
	"time"
)

type CertificateState int32

const (
	StateNew CertificateState = iota
	StateOrdered
	StateValidated
	StateComplete
	StateExpiring
	StateError
)

type Certificate struct {
	ID       int32            `db:"id"`
	Domain   string           `db:"domain"`
	State    CertificateState `db:"state"`
	Created  time.Time        `db:"created"`
	Modified time.Time        `db:"modified"`
}
