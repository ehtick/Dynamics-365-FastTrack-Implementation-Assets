# Using Dataverse Link to Microsoft Fabric with SQL Analytics Endpoint and Warehouse

Microsoft Dataverse direct link to Microsoft Fabric enables organizations to extend their Power Apps and Dynamics 365 enterprise applications (Sales), and business processes into Fabric. The Link to Microsoft Fabric feature built into Power Apps makes all your Dynamics 365 (Customer Engagement and Finance and Operations Apps) and Power Apps data available in Microsoft OneLake, the built-in data lake for Microsoft Fabric.

Dataverse also generates an enterprise-ready Fabric Lakehouse and SQL endpoint for your Power Apps and Dynamics 365 data. This makes it easier for data analysts, data engineers, and database admins to combine business data with data already present in OneLake using Spark, Python, or SQL. As data gets updated, changes are reflected in the lakehouse automatically.

Data and BI teams that are currently using SQL Server technologies (Synapse Serverless, Synapse Dedicated Pool, Azure SQL, or SQL Server) to build virtual data warehouses or data mart solutions with Dynamics 365 data can easily migrate their solution to Microsoft Fabric by using Microsoft Fabric SQL Analytics Endpoint and Fabric Datawarehouse workload.

## Setup Link to Microsoft Fabric
Follow the documentation to create Link to Microsoft Fabric  
https://learn.microsoft.com/en-us/power-apps/maker/data-platform/azure-synapse-link-view-in-fabric

## Things to consider before querying data using SQL Analytics Endpoint and Warehouse

When migrating from Export to data lake solution using Synapse Serverless database or Azure SQL database, you may run into the following challenges:
1. Fabric Lakehouse and warehouses by default are configured with case-sensitive (CS) collation Latin1_General_100_BIN2_UTF8. As a result, table names and column names become case-sensitive, and you have to change your existing TSQL script and queries to adapt to case sensitivity.
2. All Dataverse tables that have track changes on are by default selected with Fabric link. If you are only interested in just a subset of tables, you have to ignore the rest of the tables from the original lakehouse.
3. Data produced by Dataverse Fabric link may have deleted rows; you need to filter out deleted rows (IsDelete=1) while consuming the data.
4. When choosing a derived table from Finance and Operations apps, columns from the corresponding base table currently aren't included. For example, if you choose the DirPartyTable table (base table), the exported data does not contain fields from the child tables (companyinfo, dirorganizationbase, ominternalorganization, dirperson, omoperatingunit, dirorganization, omteam). To get all the columns into DirPartyTable, you must also add other child tables and then create the view using the recid columns.
5. Fabric Lakehouse tables' string columns have default collation Latin1_General_100_BIN2_UTF8. As a result, filters and joins on data become case-sensitive. For example, *where custtable.dataareaid = 'usmf'* filter is case-sensitive and only filters data that matches the case.
6. DV Fabric link SQL Endpoint have table and column name in lower case while Export to data lake have metadata in MixedCase. This could be issue if you are directly importing Tables in Power BI and doing transformation in Power Query. Power Query is case sensitive and references of the column name and tablename needs to be adjusted.
7.  Fabric Link tables string length is defaulted to varchar(8000). Fabric engine is optimized with large string length however when copying data to SQL server using pipeline and use the same schema in the target– all string field columns to varchar(8000) can cause perf issue or compatibility issue in SQL Server with existing Export to data lake tables. 

In the following section, we will discussion how all these limitation can be mitigated with simple automation process.

## Overcome challenges with SQL Analytics Endpoint and Warehouse

Follow the steps below to overcome the above challenges:
1. Create a Fabric warehouse with case-insensitive collation to make table and column names case-insensitive (challenge #1).
2. Create views on Fabric warehouse for required tables to filter the list of tables, filter deleted rows, join derived tables, match tablename , columnname and datatype with export to datalake and solve data case sensitivity.

### 1. Create Fabric warehouse with case-insensitive collation

To mitigate the problem with case-sensitive collation for SQL Analytics Endpoint, you can create Fabric warehouses with case-insensitive (CI) collation - Latin1_General_100_CI_AS_KS_WS_SC_UTF8. Currently, the only method available for creating a case-insensitive data warehouse is via REST API. This article provides a step-by-step guide on how to create a warehouse with case-insensitive collation through the REST API. It also explains how to use Visual Studio Code with the REST Client extension to facilitate the process.
https://learn.microsoft.com/en-us/fabric/data-warehouse/collation

### 2. Create Views on the Fabric warehouse

Once you have the Fabric warehouse created, you can create the views on the Fabric Warehouse using a 3-part naming convention as below to mitigate the:
*create or alter view [dbo].tablename as select columnname collation from [lakehousedatabase].[dbo].[table]*

#### A. Create stored procedure on Lakehouse SQL Analytics Endpoint

RUN THIS SCRIPT TO CREATE A STORED PROCEDURE ON SQL ANALYTICS ENDPOINT GENERATED BY DATAVERSE FABRIC LINK
STORED PROCEDURE DOES THE FOLLOWING:
1. Get schema definition for filters list of tables from Lakehouse database and generate views DDL statement.
2. Apply filter in the view for deleted rows IsDelete = null.
3. Apply logic to join derived tables like dirpartytable, companyinfo, and have all columns in the parent table.
4. Change column collation to COLLATE Latin1_General_100_CI_AS_KS_WS_SC_UTF8 to enable CASE INSENSITIVE DATA.
5. Bonus feature: For enum columns, add a translated string column to represent string value.

```sql
/*
Feb 25 2025:
1. Improvement: Added schema_map parameter to support custom column names and datatypes
Dec 14 2024 : 
1.Bug Fix: related to parameter @TablesToInclude_FnOOnly and derived table duplicate fields
2.Improvemnt: Changed the deleted record filter on the view to where {tablename}.IsDelete IS NULL
3 Improvement: @translate_enums now supports enumName or localized label  - 0 - no enum translation, 1 - enumname, 2 localized label  
*/

/* RUN THIS SCRIPT TO CREATE STORED PROCEDURE ON SQL ANALYTICS ENDPOINT GENERATED BY DATAVERSE FABRIC LINK
STORED PROCEDURE DOES FOLLOWINGS
1. Get schema definition for filters list of tables from Lakehouse database and generate views ddl statement 
2. Apply filter in the view for deleted rows IsDelete = null
3. Apply logic to join derived tables like dirpartytable, companyinfo and have all columns in the parent table
4. Change column collation to COLLATE Latin1_General_100_CI_AS_KS_WS_SC_UTF8 to enable CASE INSENTIVE DATA
5. Bonus feature: For enum columns add a translated string column {columnname}_$label to represent string value   

RUN THIS SCRIPT TO CREATE STORED PROCEDURE ON SQL ANALYTICS ENDPOINT GENERATED BY DATAVERSE MICROSOFT FABRIC LINK FEATURE
*/
CREATE  OR ALTER PROCEDURE [dbo].[Get_Tables_DDL_as_Views](
	@source_database_name varchar(200) ,
	@source_table_schema nvarchar(10), 
	@target_table_schema nvarchar(10), 
	@TablesToInclude_FnOOnly int , 
	@TablesToIncluce nvarchar(max),
	@TablesToExcluce nvarchar(max),
	@filter_deleted_rows int =1,
	@join_derived_tables int =1,
	@change_column_collation  int = 1,
	@translate_enums int =0, 
	@schema_map varchar(max) = '[]',
	@ddl_statement nvarchar(max) OUTPUT) 
AS
DECLARE @CreateViewDDL nvarchar(max); 
DECLARE @addcolumns NVARCHAR(max) = '';
DECLARE @filter_deleted_rows_clause NVARCHAR(200) = '';

declare @use_edl_metadata bit = 0

IF (@schema_map != '[]' and isjson(@schema_map) =1)
	set @use_edl_metadata = 1

IF @filter_deleted_rows = 1
	SET @filter_deleted_rows_clause = ' where {tablename}.IsDelete IS NULL '
SET @CreateViewDDL = 'CREATE OR ALTER VIEW  {target_table_schema}.{viewname}  AS 
	SELECT {selectcolumns}
	FROM  {source_database_name}.{source_table_schema}.{tablename} ';

DROP TABLE

IF EXISTS #sqltadata;
	CREATE TABLE #sqltadata (viewname NVARCHAR(200)
		,tablename NVARCHAR(200)
		,selectcolumns NVARCHAR(max)
		,isDeleteColumn INT
		,isFnOTable INT
		);

INSERT INTO #sqltadata (
	tablename
	,viewname
	,selectcolumns
	,isDeleteColumn
	,isFnOTable
	)
SELECT tablename
	,viewname
	,selectcolumns
	,isDeleteColumn
	,FnOTable
FROM (
	SELECT 
             y.TABLE_NAME as tablename,
			case 
                when @use_edl_metadata  = 1 and max(z.tablename) is not null
                    then max(z.tablename)
                else y.TABLE_NAME 
            end AS viewname,
            STRING_AGG(convert(nvarchar(max),
            '' + CASE 
            WHEN (@use_edl_metadata  = 1 and z.columnname IS NOT NULL) 
                THEN 'CAST(' + QUOTENAME(y.TABLE_NAME) + '.' + QUOTENAME(y.COLUMN_NAME) + ' AS ' + z.datatype + ')' 
            ELSE 
                QUOTENAME(y.TABLE_NAME) + '.' + QUOTENAME(y.COLUMN_NAME) 
        END
        + 
        CASE 
            WHEN @change_column_collation = 1 and COLLATION_NAME IS NOT NULL and z.datatype != 'uniqueidentifier'
                THEN ' COLLATE Latin1_General_100_CI_AS_KS_WS_SC_UTF8'
            ELSE ''
        END 
        + ' AS ' + QUOTENAME(COALESCE(z.columnname, y.COLUMN_NAME))),  ',') AS selectcolumns
		,(
			SELECT TOP 1 1
			FROM INFORMATION_SCHEMA.COLUMNS x
			WHERE x.TABLE_SCHEMA = @source_table_schema
				AND x.TABLE_NAME = y.TABLE_NAME
				AND x.COLUMN_NAME = 'IsDelete'
			) isDeleteColumn
		,(
			SELECT TOP 1 1
			FROM INFORMATION_SCHEMA.COLUMNS x
			WHERE x.TABLE_SCHEMA = @source_table_schema
				AND x.TABLE_NAME = y.TABLE_NAME
				AND x.COLUMN_NAME = 'recid'
			) FnOTable
	FROM INFORMATION_SCHEMA.COLUMNS y
	LEFT OUTER JOIN (SELECT * FROM OPENJSON(@schema_map) 
					 WITH (tablename NVARCHAR(200), columnname NVARCHAR(200), datatype NVARCHAR(200), maxLength INT)) z
	ON y.TABLE_NAME = lower(z.tablename) AND y.COLUMN_NAME = lower(z.columnname)
	WHERE y.TABLE_SCHEMA = @source_table_schema
		AND (
			@TablesToIncluce = '*'
			OR y.TABLE_NAME IN (
				SELECT value
				FROM string_split(@TablesToIncluce, ',')
				)
			)
		AND y.TABLE_NAME NOT IN (
			SELECT value
			FROM string_split(@TablesToExcluce, ',')
			)
	GROUP BY y.TABLE_NAME
	) x
WHERE (@TablesToInclude_FnOOnly = 0 or( @TablesToInclude_FnOOnly = 1 AND x.FnOTable = 1))

--SELECT *
--FROM #sqltadata

DROP TABLE IF EXISTS #enumtranslation;
	CREATE TABLE #enumtranslation (
		tablename NVARCHAR(200)
		,enumtranslation NVARCHAR(max) DEFAULT('')
		);

IF (@translate_enums > 0)
BEGIN
	DECLARE @enumtranslation_optionset NVARCHAR(max);

	SELECT @enumtranslation_optionset = string_agg(convert(NVARCHAR(max), '{"tablename":"' + tablename + '","enumtranslation":",' + enumstringcolumns + '"}'), ';')
	FROM (
		SELECT tablename
			,string_agg(convert(NVARCHAR(max), enumtranslation), ',') AS enumstringcolumns
		FROM (
			SELECT tablename
				,columnname
				,'CASE [' + tablename + '].[' + columnname + ']' + string_agg(convert(NVARCHAR(max), ' WHEN ' + convert(NVARCHAR(10), enumid)) + ' THEN ''' + enumvalue, ''' ') + ''' END AS ' + columnname + '_$label' AS enumtranslation
			FROM (
				SELECT EntityName AS tablename
					,OptionSetName AS columnname
					,GlobalOptionSetName AS enum
					,[Option] AS enumid
					 ,CASE  
					 WHEN @translate_enums = 1 then ExternalValue 
					-- LocalizedLabel is  shows in the UI
					when @translate_enums = 2 then isNull(replace(LocalizedLabel, '''', ''''''),'')
					END 
					AS enumvalue
				FROM GlobalOptionsetMetadata
				WHERE LocalizedLabelLanguageCode = 1033 -- this is english
					AND OptionSetName NOT IN ('sysdatastatecode')
				) x
			GROUP BY tablename
				,columnname
				,enum
			) y
		GROUP BY tablename
		) optionsetmetadata

	INSERT INTO #enumtranslation
	SELECT tablename
		,enumtranslation
	FROM string_split(@enumtranslation_optionset, ';')
	CROSS APPLY openjson(value) WITH (
			tablename NVARCHAR(100)
			,enumtranslation NVARCHAR(max)
			)
END

-- generate ddl for view definitions for each tables in . 
-- Begin try  
-- execute sp_executesql N'create or alter view schema.tablename as selectcolumns from sourcedb.sourceschema.tablename '  
-- End Try 
--Begin catch 
-- print ERROR_PROCEDURE() + ':' print ERROR_MESSAGE() 
--end catch

SELECT @ddl_statement = string_agg(convert(NVARCHAR(max), viewDDL), ';')
FROM (
	SELECT 'begin try  execute sp_executesql N''' + replace(replace(replace(replace(replace(replace(replace(@CreateViewDDL + (
									CASE 
										WHEN isDeleteColumn = 1
											THEN @filter_deleted_rows_clause
										ELSE ''
										END
									), '{target_table_schema}', @target_table_schema), '{selectcolumns}', CASE 
								WHEN c.tablename LIKE 'mserp_%'
									THEN ''
								WHEN isFnOTable = 1
									THEN @addcolumns
								ELSE ''
								END + c.selectcolumns + isnull(enumtranslation COLLATE Database_Default, '')), '{tablename}', c.tablename),'{viewname}', c.viewname),
								'{source_database_name}', @source_database_name), '{source_table_schema}', @source_table_schema), '''', '''''') + '''' + ' End Try Begin catch print ERROR_PROCEDURE() + '':'' print ERROR_MESSAGE() end catch' AS viewDDL
	FROM #sqltadata AS c
	LEFT OUTER JOIN #enumtranslation AS e ON c.tablename = e.tablename
	) x

--SELECT @ddl_statement AS tableddl;

--select @ddl_statement as table_ddl;
-- There is  difference in Synapse link and Export to data lake when exporting derived base tables like dirpartytable
-- For base table (Dirpartytable), Export to data lake includes all columns from the derived tables. However Synapse link only exports columns that in the AOT. 
-- This step overide the Dirpartytable view and columns from other derived tables , making table dirpartytable backward compatible
-- Table Inheritance data is available in AXBD
IF (@join_derived_tables = 1)
BEGIN
	DECLARE @ddl_fno_derived_tables NVARCHAR(max);
	DECLARE @tableinheritance NVARCHAR(max) = lower(
			'[{"parenttable":"AgreementHeader","childtables":[{"childtable":"PurchAgreementHeader"},{"childtable":"SalesAgreementHeader"}]},{"parenttable":"AgreementHeaderExt_RU","childtables":[{"childtable":"PurchAgreementHeaderExt_RU"},{"childtable":"SalesAgreementHeaderExt_RU"}]},{"parenttable":"AgreementHeaderHistoryExt_RU","childtables":[{"childtable":"PurchAgreementHeaderHistoryExt_RU"},{"childtable":"SalesAgreementHeaderHistoryExt_RU"}]},{"parenttable":"AifEndpointActionValueMap","childtables":[{"childtable":"AifPortValueMap"},{"childtable":"InterCompanyTradingValueMap"}]},{"parenttable":"BankLCLine","childtables":[{"childtable":"BankLCExportLine"},{"childtable":"BankLCImportLine"}]},{"parenttable":"CAMDataAllocationBase","childtables":[{"childtable":"CAMDataFormulaAllocationBase"},{"childtable":"CAMDataHierarchyAllocationBase"},{"childtable":"CAMDataPredefinedDimensionMemberAllocationBase"}]},{"parenttable":"CAMDataCostAccountingLedgerSourceEntryProvider","childtables":[{"childtable":"CAMDataCostAccountingLedgerCostElementEntryProvider"},{"childtable":"CAMDataCostAccountingLedgerStatisticalMeasureProvider"}]},{"parenttable":"CAMDataDataConnectorDimension","childtables":[{"childtable":"CAMDataDataConnectorChartOfAccounts"},{"childtable":"CAMDataDataConnectorCostObjectDimension"}]},{"parenttable":"CAMDataDataConnectorSystemInstance","childtables":[{"childtable":"CAMDataDataConnectorSystemInstanceAX"}]},{"parenttable":"CAMDataDataOrigin","childtables":[{"childtable":"CAMDataDataOriginDocument"}]},{"parenttable":"CAMDataDimension","childtables":[{"childtable":"CAMDataCostElementDimension"},{"childtable":"CAMDataCostObjectDimension"},{"childtable":"CAMDataStatisticalDimension"}]},{"parenttable":"CAMDataDimensionHierarchy","childtables":[{"childtable":"CAMDataDimensionCategorizationHierarchy"},{"childtable":"CAMDataDimensionClassificationHierarchy"}]},{"parenttable":"CAMDataDimensionHierarchyNode","childtables":[{"childtable":"CAMDataDimensionHierarchyNodeComposite"},{"childtable":"CAMDataDimensionHierarchyNodeLeaf"}]},{"parenttable":"CAMDataImportedDimensionMember","childtables":[{"childtable":"CAMDataImportedCostElementDimensionMember"},{"childtable":"CAMDataImportedCostObjectDimensionMember"},{"childtable":"CAMDataImportedStatisticalDimensionMember"}]},{"parenttable":"CAMDataImportedTransactionEntry","childtables":[{"childtable":"CAMDataImportedBudgetEntry"},{"childtable":"CAMDataImportedGeneralLedgerEntry"}]},{"parenttable":"CAMDataJournalCostControlUnitBase","childtables":[{"childtable":"CAMDataJournalCostControlUnit"}]},{"parenttable":"CAMDataSourceDocumentLine","childtables":[{"childtable":"CAMDataSourceDocumentLineDetail"}]},{"parenttable":"CAMDataTransactionVersion","childtables":[{"childtable":"CAMDataActualVersion"},{"childtable":"CAMDataBudgetVersion"},{"childtable":"CAMDataCalculation"},{"childtable":"CAMDataOverheadCalculation"},{"childtable":"CAMDataSourceTransactionVersion"}]},{"parenttable":"CaseDetailBase","childtables":[{"childtable":"CaseDetail"},{"childtable":"CustCollectionsCaseDetail"},{"childtable":"HcmFMLACaseDetail"}]},{"parenttable":"CatProductReference","childtables":[{"childtable":"CatCategoryProductReference"},{"childtable":"CatClassifiedProductReference"},{"childtable":"CatDistinctProductReference"},{"childtable":"CatExternalQuoteProductReference"}]},{"parenttable":"CustCollectionsLinkTable","childtables":[{"childtable":"CustCollectionsLinkActivitiesCustTrans"},{"childtable":"CustCollectionsLinkCasesActivities"}]},{"parenttable":"CustInterestTransLineIdRef","childtables":[{"childtable":"CustInterestTransLineIdRef_MarkupTrans"},{"childtable":"CustnterestTransLineIdRef_Invoice"}]},{"parenttable":"CustInvoiceLineTemplate","childtables":[{"childtable":"CustInvoiceMarkupTransTemplate"},{"childtable":"CustInvoiceStandardLineTemplate"}]},{"parenttable":"CustVendDirective_PSN","childtables":[{"childtable":"CustDirective_PSN"},{"childtable":"VendDirective_PSN"}]},{"parenttable":"CustVendRoutingSlip_PSN","childtables":[{"childtable":"CustRoutingSlip_PSN"},{"childtable":"VendRoutingSlip_PSN"}]},{"parenttable":"DMFRules","childtables":[{"childtable":"DMFRulesNumberSequence"}]},{"parenttable":"EcoResApplicationControl","childtables":[{"childtable":"EcoResCatalogControl"},{"childtable":"EcoResComponentControl"}]},{"parenttable":"EcoResNomenclature","childtables":[{"childtable":"EcoResDimBasedConfigurationNomenclature"},{"childtable":"EcoResProductVariantNomenclature"},{"childtable":"EngChgProductCategoryNomenclature"},{"childtable":"PCConfigurationNomenclature"}]},{"parenttable":"EcoResNomenclatureSegment","childtables":[{"childtable":"EcoResNomenclatureSegmentAttributeValue"},{"childtable":"EcoResNomenclatureSegmentColorDimensionValue"},{"childtable":"EcoResNomenclatureSegmentColorDimensionValueName"},{"childtable":"EcoResNomenclatureSegmentConfigDimensionValue"},{"childtable":"EcoResNomenclatureSegmentConfigDimensionValueName"},{"childtable":"EcoResNomenclatureSegmentConfigGroupItemId"},{"childtable":"EcoResNomenclatureSegmentConfigGroupItemName"},{"childtable":"EcoResNomenclatureSegmentNumberSequence"},{"childtable":"EcoResNomenclatureSegmentProductMasterName"},{"childtable":"EcoResNomenclatureSegmentProductMasterNumber"},{"childtable":"EcoResNomenclatureSegmentSizeDimensionValue"},{"childtable":"EcoResNomenclatureSegmentSizeDimensionValueName"},{"childtable":"EcoResNomenclatureSegmentStyleDimensionValue"},{"childtable":"EcoResNomenclatureSegmentStyleDimensionValueName"},{"childtable":"EcoResNomenclatureSegmentTextConstant"},{"childtable":"EcoResNomenclatureSegmentVersionDimensionValue"},{"childtable":"EcoResNomenclatureSegmentVersionDimensionValueName"}]},{"parenttable":"EcoResProduct","childtables":[{"childtable":"EcoResDistinctProduct"},{"childtable":"EcoResDistinctProductVariant"},{"childtable":"EcoResProductMaster"}]},{"parenttable":"EcoResProductMasterDimensionValue","childtables":[{"childtable":"EcoResProductMasterColor"},{"childtable":"EcoResProductMasterConfiguration"},{"childtable":"EcoResProductMasterSize"},{"childtable":"EcoResProductMasterStyle"},{"childtable":"EcoResProductMasterVersion"}]},{"parenttable":"EcoResProductWorkspaceConfiguration","childtables":[{"childtable":"EcoResProductDiscreteManufacturingWorkspaceConfiguration"},{"childtable":"EcoResProductMaintainWorkspaceConfiguration"},{"childtable":"EcoResProductProcessManufacturingWorkspaceConfiguration"},{"childtable":"EcoResProductVariantMaintainWorkspaceConfiguration"}]},{"parenttable":"EngChgEcmOriginals","childtables":[{"childtable":"EngChgEcmOriginalEcmAttribute"},{"childtable":"EngChgEcmOriginalEcmBom"},{"childtable":"EngChgEcmOriginalEcmBomTable"},{"childtable":"EngChgEcmOriginalEcmFormulaCoBy"},{"childtable":"EngChgEcmOriginalEcmFormulaStep"},{"childtable":"EngChgEcmOriginalEcmProduct"},{"childtable":"EngChgEcmOriginalEcmRoute"},{"childtable":"EngChgEcmOriginalEcmRouteOpr"},{"childtable":"EngChgEcmOriginalEcmRouteTable"}]},{"parenttable":"FBGeneralAdjustmentCode_BR","childtables":[{"childtable":"FBGeneralAdjustmentCodeICMS_BR"},{"childtable":"FBGeneralAdjustmentCodeINSSCPRB_BR"},{"childtable":"FBGeneralAdjustmentCodeIPI_BR"},{"childtable":"FBGeneralAdjustmentCodePISCOFINS_BR"}]},{"parenttable":"HRPLimitAgreementException","childtables":[{"childtable":"HRPLimitAgreementCompException"},{"childtable":"HRPLimitAgreementJobException"}]},{"parenttable":"IntercompanyActionPolicy","childtables":[{"childtable":"IntercompanyAgreementActionPolicy"}]},{"parenttable":"PaymCalendarRule","childtables":[{"childtable":"PaymCalendarCriteriaRule"},{"childtable":"PaymCalendarLocationRule"}]},{"parenttable":"PCConstraint","childtables":[{"childtable":"PCExpressionConstraint"},{"childtable":"PCTableConstraint"}]},{"parenttable":"PCProductConfiguration","childtables":[{"childtable":"PCTemplateConfiguration"},{"childtable":"PCVariantConfiguration"}]},{"parenttable":"PCTableConstraintColumnDefinition","childtables":[{"childtable":"PCTableConstraintDatabaseColumnDef"},{"childtable":"PCTableConstraintGlobalColumnDef"}]},{"parenttable":"PCTableConstraintDefinition","childtables":[{"childtable":"PCDatabaseRelationConstraintDefinition"},{"childtable":"PCGlobalTableConstraintDefinition"}]},{"parenttable":"RetailMediaResource","childtables":[{"childtable":"RetailImageResource"}]},{"parenttable":"RetailPeriodicDiscount","childtables":[{"childtable":"GUPFreeItemDiscount"},{"childtable":"RetailDiscountMixAndMatch"},{"childtable":"RetailDiscountMultibuy"},{"childtable":"RetailDiscountOffer"},{"childtable":"RetailDiscountThreshold"},{"childtable":"RetailShippingThresholdDiscounts"}]},{"parenttable":"RetailProductAttributesLookup","childtables":[{"childtable":"RetailAttributesGlobalLookup"},{"childtable":"RetailAttributesLegalEntityLookup"}]},{"parenttable":"RetailPubRetailChannelTable","childtables":[{"childtable":"RetailPubRetailMCRChannelTable"},{"childtable":"RetailPubRetailOnlineChannelTable"},{"childtable":"RetailPubRetailStoreTable"}]},{"parenttable":"RetailTillLayoutZoneReferenceLegacy","childtables":[{"childtable":"RetailTillLayoutButtonGridZoneLegacy"},{"childtable":"RetailTillLayoutImageZoneLegacy"},{"childtable":"RetailTillLayoutReportZoneLegacy"}]},{"parenttable":"SCTTracingActivity","childtables":[{"childtable":"SCTTracingActivity_Purch"}]},{"parenttable":"SysMessageTarget","childtables":[{"childtable":"SysMessageCompanyTarget"},{"childtable":"SysWorkloadMessageCompanyTarget"},{"childtable":"SysWorkloadMessageHubCompanyTarget"}]},{"parenttable":"SysPolicyRuleType","childtables":[{"childtable":"SysPolicySourceDocumentRuleType"}]},{"parenttable":"TradeNonStockedConversionLog","childtables":[{"childtable":"TradeNonStockedConversionChangeLog"},{"childtable":"TradeNonStockedConversionCheckLog"}]},{"parenttable":"UserRequest","childtables":[{"childtable":"VendRequestUserRequest"},{"childtable":"VendUserRequest"}]},{"parenttable":"VendRequest","childtables":[{"childtable":"VendRequestCategoryExtension"},{"childtable":"VendRequestCompany"},{"childtable":"VendRequestStatusChange"}]},{"parenttable":"VendVendorRequest","childtables":[{"childtable":"VendVendorRequestNewCategory"},{"childtable":"VendVendorRequestNewVendor"}]},{"parenttable":"WarrantyGroupConfigurationItem","childtables":[{"childtable":"RetailWarrantyApplicableChannel"},{"childtable":"WarrantyApplicableProduct"},{"childtable":"WarrantyGroupData"}]},{"parenttable":"AgreementHeaderHistory","childtables":[{"childtable":"PurchAgreementHeaderHistory"},{"childtable":"SalesAgreementHeaderHistory"}]},{"parenttable":"AgreementLine","childtables":[{"childtable":"AgreementLineQuantityCommitment"},{"childtable":"AgreementLineVolumeCommitment"}]},{"parenttable":"AgreementLineHistory","childtables":[{"childtable":"AgreementLineQuantityCommitmentHistory"},{"childtable":"AgreementLineVolumeCommitmentHistory"}]},{"parenttable":"BankLC","childtables":[{"childtable":"BankLCExport"},{"childtable":"BankLCImport"}]},{"parenttable":"BenefitESSTileSetupBase","childtables":[{"childtable":"BenefitESSTileSetupBenefit"},{"childtable":"BenefitESSTileSetupBenefitCredit"}]},{"parenttable":"BudgetPlanElementDefinition","childtables":[{"childtable":"BudgetPlanColumn"},{"childtable":"BudgetPlanRow"}]},{"parenttable":"BusinessEventsEndpoint","childtables":[{"childtable":"BusinessEventsAzureBlobStorageEndpoint"},{"childtable":"BusinessEventsAzureEndpoint"},{"childtable":"BusinessEventsEventGridEndpoint"},{"childtable":"BusinessEventsEventHubEndpoint"},{"childtable":"BusinessEventsFlowEndpoint"},{"childtable":"BusinessEventsServiceBusQueueEndpoint"},{"childtable":"BusinessEventsServiceBusTopicEndpoint"}]},{"parenttable":"CAMDataCostAccountingPolicy","childtables":[{"childtable":"CAMDataAccountingUnitOfMeasurePolicy"},{"childtable":"CAMDataCostAccountingAccountPolicy"},{"childtable":"CAMDataCostAccountingLedgerPolicy"},{"childtable":"CAMDataCostAllocationPolicy"},{"childtable":"CAMDataCostBehaviorPolicy"},{"childtable":"CAMDataCostControlUnitPolicy"},{"childtable":"CAMDataCostDistributionPolicy"},{"childtable":"CAMDataCostFlowAssumptionPolicy"},{"childtable":"CAMDataCostRollupPolicy"},{"childtable":"CAMDataInputMeasurementBasisPolicy"},{"childtable":"CAMDataInventoryValuationMethodPolicy"},{"childtable":"CAMDataLedgerDocumentAccountingPolicy"},{"childtable":"CAMDataOverheadRatePolicy"},{"childtable":"CAMDataRecordingIntervalPolicy"}]},{"parenttable":"CAMDataJournal","childtables":[{"childtable":"CAMDataBudgetEntryTransferJournal"},{"childtable":"CAMDataCalculationJournal"},{"childtable":"CAMDataCostAllocationJournal"},{"childtable":"CAMDataCostBehaviorCalculationJournal"},{"childtable":"CAMDataCostDistributionJournal"},{"childtable":"CAMDataGeneralLedgerEntryTransferJournal"},{"childtable":"CAMDataOverheadRateCalculationJournal"},{"childtable":"CAMDataSourceEntryTransferJournal"},{"childtable":"CAMDataStatisticalEntryTransferJournal"}]},{"parenttable":"CAMDataSourceDocumentAttributeValue","childtables":[{"childtable":"CAMDataSourceDocumentAttributeValueAmount"},{"childtable":"CAMDataSourceDocumentAttributeValueDate"},{"childtable":"CAMDataSourceDocumentAttributeValueQuantity"},{"childtable":"CAMDataSourceDocumentAttributeValueString"}]},{"parenttable":"CatPunchoutRequest","childtables":[{"childtable":"CatCXMLPunchoutRequest"}]},{"parenttable":"CatUserReview","childtables":[{"childtable":"CatUserReviewProduct"},{"childtable":"CatUserReviewVendor"}]},{"parenttable":"CatVendProdCandidateAttributeValue","childtables":[{"childtable":"CatVendorBooleanValue"},{"childtable":"CatVendorCurrencyValue"},{"childtable":"CatVendorDateTimeValue"},{"childtable":"CatVendorFloatValue"},{"childtable":"CatVendorIntValue"},{"childtable":"CatVendorTextValue"}]},{"parenttable":"CustInvLineBillCodeCustomFieldBase","childtables":[{"childtable":"CustInvLineBillCodeCustomFieldBool"},{"childtable":"CustInvLineBillCodeCustomFieldDateTime"},{"childtable":"CustInvLineBillCodeCustomFieldInt"},{"childtable":"CustInvLineBillCodeCustomFieldReal"},{"childtable":"CustInvLineBillCodeCustomFieldText"}]},{"parenttable":"DIOTAdditionalInfoForNoVendor_MX","childtables":[{"childtable":"DIOTAddlInfoForNoVendorLedger_MX"},{"childtable":"DIOTAddlInfoForNoVendorProj_MX"}]},{"parenttable":"DirPartyTable","childtables":[{"childtable":"CompanyInfo"},{"childtable":"DirOrganization"},{"childtable":"DirOrganizationBase"},{"childtable":"DirPerson"},{"childtable":"OMInternalOrganization"},{"childtable":"OMOperatingUnit"},{"childtable":"OMTeam"}]},{"parenttable":"DOMRules","childtables":[{"childtable":"DOMCatalogAmountFulfillmentTypeRules"},{"childtable":"DOMCatalogMinimumInventoryRules"},{"childtable":"DOMCatalogRules"},{"childtable":"DOMCatalogShipPriorityRules"},{"childtable":"DOMOrgFulfillmentTypeRules"},{"childtable":"DOMOrgLocationOfflineRules"},{"childtable":"DOMOrgMaximumDistanceRules"},{"childtable":"DOMOrgMaximumOrdersRules"},{"childtable":"DOMOrgMaximumRejectsRules"}]},{"parenttable":"DOMRulesLine","childtables":[{"childtable":"DOMRulesLineCatalogAmountFulfillmentTypeRules"},{"childtable":"DOMRulesLineCatalogMinimumInventoryRules"},{"childtable":"DOMRulesLineCatalogRules"},{"childtable":"DOMRulesLineCatalogShipPriorityRules"},{"childtable":"DOMRulesLineOrgFulfillmentTypeRules"},{"childtable":"DOMRulesLineOrgLocationOfflineRules"},{"childtable":"DOMRulesLineOrgMaximumDistanceRules"},{"childtable":"DOMRulesLineOrgMaximumOrdersRules"},{"childtable":"DOMRulesLineOrgMaximumRejectsRules"}]},{"parenttable":"EcoResCategory","childtables":[{"childtable":"PCClass"}]},{"parenttable":"EcoResInstanceValue","childtables":[{"childtable":"CatalogProductInstanceValue"},{"childtable":"CustomerInstanceValue"},{"childtable":"EcoResCategoryInstanceValue"},{"childtable":"EcoResEngineeringProductCategoryAttributeInstanceValue"},{"childtable":"EcoResProductInstanceValue"},{"childtable":"EcoResReleasedEngineeringProductVersionAttributeInstanceValue"},{"childtable":"GUPPriceTreeInstanceValue"},{"childtable":"GUPRebateDateInstanceValue"},{"childtable":"GUPRetailChannelInstanceValue"},{"childtable":"GUPSalesQuotationInstanceValue"},{"childtable":"GUPSalesTableInstanceValue"},{"childtable":"PCComponentInstanceValue"},{"childtable":"RetailCatalogProdInternalOrgInstanceVal"},{"childtable":"RetailChannelInstanceValue"},{"childtable":"RetailInternalOrgProductInstanceValue"},{"childtable":"RetailSalesTableInstanceValue"},{"childtable":"TMSLoadBuildStrategyAttribValueSet"}]},{"parenttable":"EcoResProductVariantDimensionValue","childtables":[{"childtable":"EcoResProductVariantColor"},{"childtable":"EcoResProductVariantConfiguration"},{"childtable":"EcoResProductVariantSize"},{"childtable":"EcoResProductVariantStyle"},{"childtable":"EcoResProductVariantVersion"}]},{"parenttable":"EcoResValue","childtables":[{"childtable":"EcoResBooleanValue"},{"childtable":"EcoResCurrencyValue"},{"childtable":"EcoResDateTimeValue"},{"childtable":"EcoResFloatValue"},{"childtable":"EcoResIntValue"},{"childtable":"EcoResReferenceValue"},{"childtable":"EcoResTextValue"}]},{"parenttable":"EntAssetMaintenancePlanLine","childtables":[{"childtable":"EntAssetMaintenancePlanLineCounter"},{"childtable":"EntAssetMaintenancePlanLineTime"}]},{"parenttable":"HRPDefaultLimit","childtables":[{"childtable":"HRPDefaultLimitCompensationRule"},{"childtable":"HRPDefaultLimitJobRule"}]},{"parenttable":"KanbanQuantityPolicyDemandPeriod","childtables":[{"childtable":"KanbanQuantityDemandPeriodFence"},{"childtable":"KanbanQuantityDemandPeriodSeason"}]},{"parenttable":"MarkupMatchingTrans","childtables":[{"childtable":"VendInvoiceInfoLineMarkupMatchingTrans"},{"childtable":"VendInvoiceInfoSubMarkupMatchingTrans"}]},{"parenttable":"MarkupPeriodChargeInvoiceLineBase","childtables":[{"childtable":"MarkupPeriodChargeInvoiceLineBaseMonetary"},{"childtable":"MarkupPeriodChargeInvoiceLineBaseQuantity"},{"childtable":"MarkupPeriodChargeInvoiceLineBaseQuantityMinAmount"}]},{"parenttable":"PayrollPayStatementLine","childtables":[{"childtable":"PayrollPayStatementBenefitLine"},{"childtable":"PayrollPayStatementEarningLine"},{"childtable":"PayrollPayStatementTaxLine"}]},{"parenttable":"PayrollProviderTaxRegion","childtables":[{"childtable":"PayrollTaxRegionForSymmetry"}]},{"parenttable":"PayrollTaxEngineTaxCode","childtables":[{"childtable":"PayrollTaxEngineTaxCodeForSymmetry"}]},{"parenttable":"PayrollTaxEngineWorkerTaxRegion","childtables":[{"childtable":"PayrollWorkerTaxRegionForSymmetry"}]},{"parenttable":"PCPriceElement","childtables":[{"childtable":"PCPriceBasePrice"},{"childtable":"PCPriceExpressionRule"}]},{"parenttable":"PCRuntimeCache","childtables":[{"childtable":"PCRuntimeCacheXml"}]},{"parenttable":"PCTemplateAttributeBinding","childtables":[{"childtable":"PCTemplateCategoryAttribute"},{"childtable":"PCTemplateConstant"}]},{"parenttable":"RetailChannelTable","childtables":[{"childtable":"RetailDirectSalesChannel"},{"childtable":"RetailMCRChannelTable"},{"childtable":"RetailOnlineChannelTable"},{"childtable":"RetailStoreTable"}]},{"parenttable":"RetailPeriodicDiscountLine","childtables":[{"childtable":"GUPFreeItemDiscountLine"},{"childtable":"RetailDiscountLineMixAndMatch"},{"childtable":"RetailDiscountLineMultibuy"},{"childtable":"RetailDiscountLineOffer"},{"childtable":"RetailDiscountLineThresholdApplying"}]},{"parenttable":"RetailReturnPolicyLine","childtables":[{"childtable":"RetailReturnInfocodePolicyLine"},{"childtable":"RetailReturnReasonCodePolicyLine"}]},{"parenttable":"RetailTillLayoutZoneReference","childtables":[{"childtable":"RetailTillLayoutButtonGridZone"},{"childtable":"RetailTillLayoutImageZone"},{"childtable":"RetailTillLayoutReportZone"}]},{"parenttable":"ServicesParty","childtables":[{"childtable":"ServicesCustomer"},{"childtable":"ServicesEmployee"}]},{"parenttable":"SysPolicyRule","childtables":[{"childtable":"CatCatalogPolicyRule"},{"childtable":"HcmBenefitEligibilityRule"},{"childtable":"HRPDefaultLimitRule"},{"childtable":"HRPLimitAgreementRule"},{"childtable":"HRPLimitRequestCurrencyRule"},{"childtable":"PayrollPremiumEarningGenerationRule"},{"childtable":"PurchReApprovalPolicyRuleTable"},{"childtable":"PurchReqControlRFQRule"},{"childtable":"PurchReqControlRule"},{"childtable":"PurchReqSourcingPolicyRule"},{"childtable":"RequisitionPurposeRule"},{"childtable":"RequisitionReplenishCatAccessPolicyRule"},{"childtable":"RequisitionReplenishControlRule"},{"childtable":"SysPolicySourceDocumentRule"},{"childtable":"TrvPolicyRule"},{"childtable":"TSPolicyRule"}]},{"parenttable":"SysTaskRecorderNode","childtables":[{"childtable":"SysTaskRecorderNodeAnnotationUserAction"},{"childtable":"SysTaskRecorderNodeCommandUserAction"},{"childtable":"SysTaskRecorderNodeFormUserAction"},{"childtable":"SysTaskRecorderNodeFormUserActionInputOutput"},{"childtable":"SysTaskRecorderNodeInfoUserAction"},{"childtable":"SysTaskRecorderNodeMenuItemUserAction"},{"childtable":"SysTaskRecorderNodePropertyUserAction"},{"childtable":"SysTaskRecorderNodeScope"},{"childtable":"SysTaskRecorderNodeTaskUserAction"},{"childtable":"SysTaskRecorderNodeUserAction"},{"childtable":"SysTaskRecorderNodeValidationUserAction"}]},{"parenttable":"SysUserRequest","childtables":[{"childtable":"HcmWorkerUserRequest"},{"childtable":"VendVendorPortalUserRequest"}]},{"parenttable":"TrvEnhancedData","childtables":[{"childtable":"TrvEnhancedCarRentalData"},{"childtable":"TrvEnhancedHotelData"},{"childtable":"TrvEnhancedItineraryData"}]}]'
		)
	DECLARE @backwardcompatiblecolumns NVARCHAR(max) = '_SysRowId,DataLakeModified_DateTime,$FileName,LSN,LastProcessedChange_DateTime';
	DECLARE @exlcudecolumns NVARCHAR(max) = 'Id,SinkCreatedOn,SinkModifiedOn,modifieddatetime,modifiedby,modifiedtransactionid,dataareaid,recversion,partition,sysrowversion,recid,tableid,versionnumber,createdon,modifiedon,IsDelete,PartitionId,createddatetime,createdby,createdtransactionid,PartitionId,sysdatastatecode,createdonpartition';

	WITH table_hierarchy
	AS (
		SELECT parenttable
			,string_agg(convert(NVARCHAR(max), childtable), ',') AS childtables
			,string_agg(convert(NVARCHAR(max), joinclause), ' ') AS joins
			,string_agg(convert(NVARCHAR(max), columnnamelist), ',') AS columnnamelists
		FROM (
			SELECT parenttable
				,childtable
				,'LEFT OUTER JOIN ' + childtable + ' AS ' + childtable + ' ON ' + parenttable + '.recid = ' + childtable + '.recid' AS joinclause
				,(
					SELECT STRING_AGG(convert(VARCHAR(max), 
		
					CASE WHEN (@use_edl_metadata  = 1 and z.columnname IS NOT NULL) 
                		THEN 'CAST(' + QUOTENAME(C.TABLE_NAME) + '.' + QUOTENAME(C.COLUMN_NAME) + ' AS ' + z.datatype + ')' 
            		ELSE QUOTENAME(C.TABLE_NAME) + '.' + QUOTENAME(C.COLUMN_NAME) END
					+ ' AS ' + QUOTENAME(COALESCE(z.columnname, C.COLUMN_NAME))
					), ',')
					FROM INFORMATION_SCHEMA.COLUMNS C
					LEFT OUTER JOIN (SELECT * FROM OPENJSON(@schema_map) 
					WITH (tablename NVARCHAR(200), columnname NVARCHAR(200), datatype NVARCHAR(200), maxLength INT)) z
					ON C.TABLE_NAME = lower(z.tablename) AND C.COLUMN_NAME = lower(z.columnname)
					WHERE TABLE_SCHEMA = @target_table_schema
						AND TABLE_NAME = childtable
						AND COLUMN_NAME NOT IN (
							SELECT value
							FROM string_split(@backwardcompatiblecolumns + ',' + @exlcudecolumns, ',')
							)
					) AS columnnamelist
			FROM openjson(@tableinheritance) WITH (
					parenttable NVARCHAR(200)
					,childtables NVARCHAR(max) AS JSON
					)
			CROSS APPLY openjson(childtables) WITH (childtable NVARCHAR(200))
			WHERE childtable IN (
					SELECT TABLE_NAME
					FROM INFORMATION_SCHEMA.COLUMNS C
					WHERE TABLE_SCHEMA = @target_table_schema
						AND C.TABLE_NAME = childtable
					)
			) x
		GROUP BY parenttable
		)
	SELECT @ddl_fno_derived_tables = string_agg(convert(NVARCHAR(max), viewDDL), ';')
	FROM (
		SELECT 'begin try  execute sp_executesql N''' + replace(replace(replace(replace(replace(replace(replace(@CreateViewDDL + ' ' + h.joins + @filter_deleted_rows_clause, '{target_table_schema}', @target_table_schema), '{selectcolumns}', @addcolumns + selectcolumns + isnull(enumtranslation COLLATE Database_Default, '') + ',' + h.columnnamelists), '{viewname}', c.viewname), '{tablename}', c.tablename), '{source_database_name}', @source_database_name), '{source_table_schema}', @source_table_schema), '''', '''''') + '''' + ' End Try Begin catch print ERROR_PROCEDURE() + '':'' print ERROR_MESSAGE() end catch' AS viewDDL
		FROM #sqltadata c
		LEFT OUTER JOIN #enumtranslation AS e ON c.tablename = e.tablename
		INNER JOIN table_hierarchy h ON c.tablename = h.parenttable
		) X;
	--select @ddl_fno_derived_tables
	SET @ddl_statement = @ddl_statement + ';' + isnull(@ddl_fno_derived_tables, '')

END
GO
```
#### B. Get schema map from existing Export to data lake Synapse serverless database
Run Following script on the Synapse serverless database that is associated with Export to data lake to get the columnname and datatype - copy the output and use that in the next script

```
select TABLE_NAME as tablename, 
COLUMN_NAME as columnname,
DATA_TYPE 
+ case 
    when  CHARACTER_MAXIMUM_LENGTH is not null then '(' + cast(CHARACTER_MAXIMUM_LENGTH as varchar(10)) + ')' 
    when CHARACTER_MAXIMUM_LENGTH = -1 then '(max)' 
    when DATA_TYPE = 'decimal' then '(' + cast(NUMERIC_PRECISION as varchar(10)) + ',' + cast(NUMERIC_SCALE as varchar(10)) + ')'
else '' end as datatype
from INFORMATION_SCHEMA.COLUMNS
where TABLE_SCHEMA = 'dbo' 
and TABLE_NAME in (select distinct TABLE_NAME 
from INFORMATION_SCHEMA.COLUMNS where TABLE_SCHEMA = 'dbo' and Column_name = '_SysRowId') 
FOR JSON AUTO
```

#### C. Execute script to create the views on Fabric 

RUN THIS SCRIPT ON TARGET FABRIC WAREHOUSE DATABASE TO CREATE VIEWS. 
Update the 
Update 
```{=sql}
/*
RUN THIS SCRIPT ON TARGET FABRIC WAREHOUSE DATABASE TO CREATE VIEWS
Update 
*/
DECLARE 
@source_database_name varchar(200) = '{UpdateSourceLakeHouseDatabaseNameHere}',
@source_table_schema nvarchar(10)='dbo', 
@target_table_schema nvarchar(10)='dbo', 
@TablesToInclude_FnOOnly int =1, -- use 1 to select fno tables only , 0 to select all the tables in the lakehouse 
@TablesToIncluce nvarchar(max) = '*', -- use * to include all table,  comma seperated list to 
@TablesToExcluce nvarchar(max) = '*', -- use comma seperated list to exclude list of tables, * no table excluded
	
-- change feature switch as applicable 1 = on, 0 = off
@filter_deleted_rows int =1,
@join_derived_tables int =1,
@change_column_collation  int = 1,
@translate_enums int =0, --@translate_enums now supports enumName or localized label  - 0 - no enum translation, 1 - enumname, 2 localized label  
@ddl_statement nvarchar(max);

declare @schema_map varchar(max) ='[]'; -- update schema map output from the previous step here

EXECUTE  [UpdateSourceLakeHouseDatabaseNameHere].[dbo].[Get_Tables_DDL_as_Views] 
   @source_database_name
  ,@source_table_schema
  ,@target_table_schema
  ,@TablesToInclude_FnOOnly
  ,@TablesToIncluce
  ,@TablesToExcluce
  ,@filter_deleted_rows
  ,@join_derived_tables
  ,@change_column_collation
  ,@translate_enums
  ,@schema_map
  ,@ddl_statement = @ddl_statement OUTPUT;

execute sp_executesql @ddl_statement;
```
