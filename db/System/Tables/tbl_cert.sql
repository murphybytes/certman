CREATE TABLE [System].[tbl_cert]
(
  [id] INT IDENTITY(1,1) PRIMARY KEY,
  [domain] NVARCHAR(255) NOT NULL,
  [state] INT DEFAULT 0,
  [created] DATETIME2(7) DEFAULT SYSUTCDATETIME (),
  [modified] DATETIME2(7) DEFAULT SYSUTCDATETIME (),
  INDEX IX_domain UNIQUE ([domain])  
)




