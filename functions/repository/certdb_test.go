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
func registerTestDomain(ctx context.Context, t *testing.T, cdb *Certdb, domain string, emails ...string) int32 {
	t.Helper()
	id, err := cdb.RegisterDomain(ctx, domain, emails)
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

func getTestContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	return ctx 
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
func TestNotificationEmailsSimple(t *testing.T) {
	ctx := getTestContext(t)
	domain := randomDomain()
	db := newTestDB(t)
	id := registerTestDomain(ctx, t, db, domain, "m1@foo.com", "m2@foo.com")
	n, err := db.GetCertificateNotifications(ctx, id)
	assert.Nil(t, err)
	assert.Len(t, n, 2)
}

// Emails are stored as parameters, so quotes and SQL in an address are saved
// verbatim instead of breaking or altering the insert.
func TestNotificationEmailsAreNotSQL(t *testing.T) {
	ctx := getTestContext(t)
	db := newTestDB(t)
	emails := []string{
		"o'brien@foo.com",
		"x@foo.com'); DELETE FROM System.tbl_notification; --",
	}
	id := registerTestDomain(ctx, t, db, randomDomain(), emails...)
	n, err := db.GetCertificateNotifications(ctx, id)
	require.NoError(t, err)
	stored := []string{}
	for _, notification := range n {
		stored = append(stored, notification.Email)
	}
	assert.ElementsMatch(t, emails, stored)
}

func TestNotificationEmails(t *testing.T) {
	ctx := getTestContext(t)
	db := newTestDB(t)
	domain1 := randomDomain()
	id1 := registerTestDomain(ctx, t, db, domain1, "m1@foo.com")
	domain2 := randomDomain()
	// same email can get notifications from different domains 
	id2 := registerTestDomain(ctx, t, db, domain2, "m1@foo.com", "m3@foo.com")
	n1, err := db.GetCertificateNotifications(ctx,id1)
	assert.Nil(t,err)
	assert.Len(t, n1, 1)
	err = db.DeleteCertificateNotification(ctx,n1[0].ID)
	assert.Nil(t, err) 
	n1, err = db.GetCertificateNotifications(ctx,id1)
	assert.Nil(t, err)
	assert.Len(t, n1, 0)
	cid1, err := db.AddCertificateNotification(ctx,id2, "m4@foo.com")
	assert.Nil(t, err)
	assert.NotEqual(t,cid1, 0 )
	n2, err := db.GetCertificateNotifications(ctx,id2)
	assert.Nil(t, err)
	assert.Len(t, n2, 3)
	// can't add email to same domain twice 
	_, err = db.AddCertificateNotification(ctx,id2, "m4@foo.com")
	assert.NotNil(t, err)
}

func TestFetchPending(t *testing.T) {
	orderedDomain := randomDomain()
	newDomain := randomDomain()
	errorDomain := randomDomain()
	db := newTestDB(t)
	ctx := getTestContext(t)
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
	ctx := getTestContext(t)
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
