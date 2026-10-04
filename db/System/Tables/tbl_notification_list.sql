CREATE TABLE [System].[tbl_notification_list]
(
  [id] INT IDENTITY(1,1) PRIMARY KEY,
  [cert_id] INT NOT NULL,
  CONSTRAINT FK_email_cert FOREIGN KEY (cert_id)
    REFERENCES System.tbl_cert(id),
  [email] NVARCHAR(255) NOT NULL,
  INDEX IX_email UNIQUE ([email], [cert_id])
)
