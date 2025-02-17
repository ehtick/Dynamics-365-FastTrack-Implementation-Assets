/**
 * SAMPLE CODE NOTICE
 * 
 * THIS SAMPLE CODE IS MADE AVAILABLE AS IS.  MICROSOFT MAKES NO WARRANTIES, WHETHER EXPRESS OR IMPLIED,
 * OF FITNESS FOR A PARTICULAR PURPOSE, OF ACCURACY OR COMPLETENESS OF RESPONSES, OF RESULTS, OR CONDITIONS OF MERCHANTABILITY.
 * THE ENTIRE RISK OF THE USE OR THE RESULTS FROM THE USE OF THIS SAMPLE CODE REMAINS WITH THE USER.
 * NO TECHNICAL SUPPORT IS PROVIDED.  YOU MAY NOT DISTRIBUTE THIS CODE UNLESS YOU HAVE A LICENSE AGREEMENT WITH MICROSOFT THAT ALLOWS YOU TO DO SO.
 */

 -- Create the extension table to store the custom fields.

IF (SELECT OBJECT_ID('[ext].[COMMERCEEVENTSSYNCTABLE]')) IS NULL 
BEGIN
    CREATE TABLE
        [ext].[COMMERCEEVENTSSYNCTABLE]
    (
        [EVENTLASTSYNCTDATETIME]     [datetime] NOT NULL,
        [REPLICATIONCOUNTERFROMORIGIN] [int] IDENTITY(1,1) NOT NULL,
        [ROWVERSION] [timestamp] NOT NULL,
        [DATAAREAID] [nvarchar](4) NOT NULL,
        [APPNAME]   [nvarchar](20) NOT NULL,
        CONSTRAINT [I_COMMERCEEVENTSSYNCTABLE_LASTSYNCDATETIME] PRIMARY KEY CLUSTERED 
        (
            [APPNAME] ASC,
            [EVENTLASTSYNCTDATETIME]  ASC,
            [DATAAREAID] ASC
        ) WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
    ) ON [PRIMARY]

END
GO

GRANT SELECT, INSERT, UPDATE, DELETE ON OBJECT::[ext].[COMMERCEEVENTSSYNCTABLE] TO [UsersRole]
GO

GRANT SELECT, INSERT, UPDATE, DELETE ON OBJECT::[ext].[COMMERCEEVENTSSYNCTABLE] TO [DeployExtensibilityRole]
GO

GRANT SELECT, INSERT, UPDATE, DELETE ON OBJECT::[ext].[COMMERCEEVENTSSYNCTABLE] TO [DataSyncUsersRole]
GO

-- Create a stored procedure CRT can use to add entries to the custom table.

IF OBJECT_ID(N'[ext].[INSERTCOMMERCEEVENTSYNCTABLE]', N'P') IS NOT NULL
    DROP PROCEDURE [ext].[INSERTCOMMERCEEVENTSYNCTABLE]
GO

CREATE PROCEDURE [ext].[INSERTCOMMERCEEVENTSYNCTABLE]
    @d_LastsyncDatetime     datetime,
    @s_DataAreaId           [nvarchar](4),
    @s_AppName              [nvarchar](20)
AS
BEGIN
    SET NOCOUNT ON

    INSERT INTO
         ext.COMMERCEEVENTSSYNCTABLE
        (EVENTLASTSYNCTDATETIME,DATAAREAID,APPNAME)
    OUTPUT
        INSERTED.EVENTLASTSYNCTDATETIME,INSERTED.DATAAREAID,INSERTED.APPNAME
    VALUES
        (@d_LastsyncDatetime,@s_DataAreaId,@s_AppName)
END;
GO

GRANT EXECUTE ON [ext].[INSERTCOMMERCEEVENTSYNCTABLE] TO [UsersRole];
GO

GRANT EXECUTE ON [ext].[INSERTCOMMERCEEVENTSYNCTABLE] TO [DeployExtensibilityRole];
GO

GRANT EXECUTE ON [ext].[INSERTCOMMERCEEVENTSYNCTABLE] TO [PublishersRole];
GO

-- Create the custom view that can query a complete Commerce Event Entity.

IF (SELECT OBJECT_ID('[ext].[COMMERCEEVENTSLASTSYNCVIEW]')) IS NOT NULL
    DROP VIEW [ext].[COMMERCEEVENTSLASTSYNCVIEW]
GO

CREATE VIEW [ext].[COMMERCEEVENTSLASTSYNCVIEW] AS
(
    SELECT
        et.EVENTLASTSYNCTDATETIME,
        et.DATAAREAID as EVENTLASTSYNCDATAAREAID,
        et.APPNAME
    FROM
        [ext].[COMMERCEEVENTSSYNCTABLE] et
)
GO

GRANT SELECT ON OBJECT::[ext].[COMMERCEEVENTSLASTSYNCVIEW] TO [UsersRole];
GO

GRANT SELECT ON OBJECT::[ext].[COMMERCEEVENTSLASTSYNCVIEW] TO [DeployExtensibilityRole];
GO

