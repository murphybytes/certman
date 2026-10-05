package repository

import (
	"context"
	"database/sql"
	"math/rand/v2"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// connStringEnv names the environment variable holding the test database's
// connection string. `make test-db ENV=dev` sets it from the deployed resources.
const connStringEnv = "CERTDB_CONNECTION_STRING"

// newTestDB connects to the database named by CERTDB_CONNECTION_STRING and
// closes it when the test ends. Tests using it are skipped if the variable is unset.
func newTestDB(t *testing.T) *Certdb {
	t.Helper()

	connString := os.Getenv(connStringEnv)
	if connString == "" {
		t.Skipf("%s not set; skipping database test", connStringEnv)
	}

	db, err := New(t.Context(), connString)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() {
		if err := db.Close(); err != nil {
			t.Errorf("Close: %v", err)
		}
	})
	return db
}

// registerTestDomain registers domain, failing the test immediately if that
// fails, and unregisters it when the test ends. Tests only remove the rows they
// created, so they're safe to run against a shared database.
func registerTestDomain(ctx context.Context, t *testing.T, cdb *Certdb, domain string) int32 {
	t.Helper()
	id, err := cdb.RegisterDomain(ctx, domain)
	require.NoError(t, err, "registering %s", domain)
	t.Cleanup(func() {
		// The test's context may be done by now, so clean up with a fresh one.
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := cdb.UnregisterDomain(ctx, id); err != nil {
			t.Errorf("unregistering %s: %v", domain, err)
		}
	})
	return id
}

// randomDomain returns a random 12-character domain name, eight lowercase
// letters followed by ".com" (e.g. "xyzabdef.com"), so tests don't collide
// with each other or with leftover rows.
func randomDomain() string {
	const letters = "abcdefghijklmnopqrstuvwxyz"
	name := make([]byte, 8)
	for i := range name {
		name[i] = letters[rand.IntN(len(letters))]
	}
	return string(name) + ".com"
}

func TestNew(t *testing.T) {
	newTestDB(t)
}

func TestFetchPending(t *testing.T) {
	orderedDomain := randomDomain()
	newDomain := randomDomain()
	errorDomain := randomDomain()
	db := newTestDB(t)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	id := registerTestDomain(ctx, t, db, orderedDomain)
	require.NoError(t, db.SetState(ctx, id, StateOrdered))
	registerTestDomain(ctx, t, db, newDomain)
	id = registerTestDomain(ctx, t, db, errorDomain)
	require.NoError(t, db.SetState(ctx, id, StateError))

	certs, err := db.GetDomainsWithPendingCertificates(ctx)
	require.NoError(t, err)
	// The table may hold other rows, so only check the domains this test created.
	domains := []string{}
	for _, cert := range certs {
		domains = append(domains, cert.Domain)
	}
	assert.Contains(t, domains, orderedDomain)
	assert.Contains(t, domains, newDomain)
	assert.NotContains(t, domains, errorDomain)
}

func TestCertCrud(t *testing.T) {
	db := newTestDB(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	domain := randomDomain()
	id := registerTestDomain(ctx, t, db, domain)
	assert.NotEqual(t, int32(0), id)

	cert, err := db.GetCertificateInfo(ctx, id)
	require.NoError(t, err)
	assert.Equal(t, domain, cert.Domain)
	assert.Equal(t, StateNew, cert.State)

	require.NoError(t, db.SetState(ctx, id, StateOrdered))
	cert, err = db.GetCertificateInfo(ctx, id)
	require.NoError(t, err)
	assert.Equal(t, StateOrdered, cert.State)
	assert.True(t, cert.Modified.After(cert.Created), "modified %v should be after created %v", cert.Modified, cert.Created)

	require.NoError(t, db.UnregisterDomain(ctx, id))
	_, err = db.GetCertificateInfo(ctx, id)
	assert.ErrorIs(t, err, sql.ErrNoRows)
	assert.ErrorIs(t, db.SetState(ctx, id, StateOrdered), sql.ErrNoRows)
}
