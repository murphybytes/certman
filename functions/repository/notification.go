package repository

type Notification struct {
	ID int32 `db:"id"`
	Email string `db:"email"`
}
