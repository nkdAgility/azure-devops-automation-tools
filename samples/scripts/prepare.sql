ALTER DATABASE [Collection] SET RECOVERY SIMPLE;

USE [Collection]
CREATE LOGIN msft2 WITH PASSWORD = '?????????'
CREATE USER msft2 FOR LOGIN msft2 WITH DEFAULT_SCHEMA=[dbo]
EXEC sp_addrolemember @rolename='TFSEXECROLE', @membername='msft2'