-- Sample data from the brief, loaded as the pipeline would leave it after the 2026-10-12 S1 snapshot.
-- Used to prove the U2/U3/U4 queries. All data synthetic (from the brief).

-- ---------------------------------------------------------------- lineage
INSERT INTO ingest_batch (batch_id, source_code, received_at, s3_path, row_count, status, parser_version) VALUES
 ('00000000-0000-0000-0000-000000000105','S1','2026-10-05 06:00+00','s3://raw/s1/received_date=2026-10-05/fda_inspections.csv',3,'LOADED','s1-parser-1.0'),
 ('00000000-0000-0000-0000-000000000112','S1','2026-10-12 06:00+00','s3://raw/s1/received_date=2026-10-12/fda_inspections.csv',2,'LOADED','s1-parser-1.0'),
 ('00000000-0000-0000-0000-000000000201','S2','2026-10-01 03:00+00','s3://raw/s2/received_date=2026-10-01/eu_gmp.json',1,'LOADED','s2-parser-1.0'),
 ('00000000-0000-0000-0000-000000000302','S3','2026-10-02 09:00+00','s3://raw/s3/received_date=2026-10-02/WL-320-26-118.json',1,'LOADED','s3-parser-1.0');

-- ---------------------------------------------------------------- our factories
INSERT INTO dim_site (site_key, site_name, country_code, city, address) VALUES
 ('S-000001','Acme Pharma Unit II, Sangareddy','IN','hyderabad','plot 14 ida pashamylaram sangareddy telangana 502307'),
 ('S-000002','Acme Pharma Unit I, Visakhapatnam','IN','visakhapatnam',NULL);

-- ---------------------------------------------------------------- bridge
INSERT INTO dim_site_identifier
 (identifier_type, identifier_value, valid_from, site_key, match_method, match_score, match_evidence, matching_rules_version, decided_by) VALUES
 ('FEI','3004521877','2026-10-05 06:05+00','S-000001','EXACT_ID',1.0,'{"rule":"same FEI"}','er-1.0','system:er-1.0'),
 ('FEI','3009876543','2026-10-05 06:05+00','S-000002','EXACT_ID',1.0,'{"rule":"same FEI"}','er-1.0','system:er-1.0'),
 ('EU_SITE_REF','LOC-118842','2026-10-01 03:05+00','S-000001','FUZZY',0.91,
    '{"name_sim":0.82,"address_sim":0.95,"same_country":true,"same_city_block":true}','er-1.0','system:er-1.0'),
 ('LETTER_ID','WL-320-26-118','2026-10-03 10:00+00','S-000001','STEWARD',1.0,
    '{"address_sim":0.93,"note":"Plot 14 IDA Pashamylaram matches EU record"}','er-1.0','steward:priya'),
 ('WATCH_ID','9912','2026-10-14 10:00+00','S-000001','FUZZY',0.87,
    '{"name_sim":0.84,"same_country":true,"city_in_name":"hyderabad"}','er-1.0','system:er-1.0');

-- ---------------------------------------------------------------- S1 inspections (two snapshots diffed)
-- Snapshot 10-05 introduced three rows. Snapshot 10-12: IN-2041187 VAI→OAI (CORRECT), IN-2040551 gone (RETRACT).
INSERT INTO fact_inspection
 (inspection_id, valid_from, valid_to, is_current, record_status, batch_id, fei_number, firm_name_as_published, city, country_code,
  inspection_end_date, inspection_end_date_as_published, classification, product_type, published_date) VALUES
 ('IN-2041187','2026-10-05 06:00+00','2026-10-12 06:00+00',false,'ACTIVE','00000000-0000-0000-0000-000000000105',
   '3004521877','Acme Pharma Pvt. Ltd.','Hyderabad','IN','2026-08-14','2026-08-14','VAI','Drugs','2026-09-30'),
 ('IN-2041187','2026-10-12 06:00+00','infinity',true,'ACTIVE','00000000-0000-0000-0000-000000000112',
   '3004521877','Acme Pharma Pvt. Ltd.','Hyderabad','IN','2026-08-14','2026-08-14','OAI','Drugs','2026-09-30'),
 ('IN-2039902','2026-10-05 06:00+00','infinity',true,'ACTIVE','00000000-0000-0000-0000-000000000105',
   '3004521877','ACME PHARMACEUTICALS PRIVATE LIMITED - UNIT II','Hyderabad','IN','2026-08-02','08/02/2026','NAI','Drugs','2026-08-28'),
 ('IN-2040551','2026-10-05 06:00+00','2026-10-12 06:00+00',false,'ACTIVE','00000000-0000-0000-0000-000000000105',
   '3009876543','Acme Pharma Pvt Ltd - Unit I','Visakhapatnam','IN','2026-07-30','2026-07-30','OAI','Drugs','2026-09-12'),
 ('IN-2040551','2026-10-12 06:00+00','infinity',true,'RETRACTED','00000000-0000-0000-0000-000000000112',
   '3009876543','Acme Pharma Pvt Ltd - Unit I','Visakhapatnam','IN','2026-07-30','2026-07-30','OAI','Drugs','2026-09-12');

-- ---------------------------------------------------------------- S2
INSERT INTO fact_gmp_document
 (doc_ref, valid_from, record_status, batch_id, doc_type, site_ref, site_name_as_published, address_as_published, country_code,
  issuing_authority, inspection_end_date, issued_date, status) VALUES
 ('EUGMP-NCR-2026-0412','2026-10-01 03:00+00','ACTIVE','00000000-0000-0000-0000-000000000201','NON_COMPLIANCE','LOC-118842',
  'Acme Pharma Private Ltd, Unit 2','Plot 14, IDA Pashamylaram, Sangareddy, Telangana 502307','IN','ANSM (FR)','2026-07-21','2026-09-03','ACTIVE');

-- ---------------------------------------------------------------- S3
INSERT INTO fact_warning_letter
 (letter_id, valid_from, record_status, batch_id, fei_number, recipient_firm_as_published, recipient_address_as_published, country_code,
  issue_date, subject, body_s3_path, source_url, nlp_status) VALUES
 ('WL-320-26-118','2026-10-02 09:00+00','ACTIVE','00000000-0000-0000-0000-000000000302',NULL,'Acme Pharma Pvt Ltd',
  'Plot No. 14, IDA Pashamylaram, Sangareddy Dist., Telangana, India','IN','2026-10-02','CGMP/Finished Pharmaceuticals/Adulterated',
  's3://raw/s3/received_date=2026-10-02/WL-320-26-118.txt','https://example.gov/wl/320-26-118','DONE');

INSERT INTO fact_letter_tag (letter_id, nlp_model_version, tag, confidence) VALUES
 ('WL-320-26-118','nlp-2.1','DATA_INTEGRITY',0.94),
 ('WL-320-26-118','nlp-2.1','CGMP_DEVIATION',0.88),
 ('WL-320-26-118','nlp-2.1','ADULTERATION',0.71);

-- ---------------------------------------------------------------- S4: the four events applied in arrival order
-- e-88f1 v1, e-91c3 v2, e-88f1 again (rejected by PK), e-93aa v3 RETRACT of an unseen action.
INSERT INTO fact_enforcement_action
 (action_id, action_version, event_id, operation, action_type, agency, fei_number, firm_name, country_code, product_codes, effective_date, event_time, loaded_at) VALUES
 ('IA-66-40-0098',1,'e-88f1','UPSERT','IMPORT_ALERT','FDA','3004521877','Acme Pharma Pvt Ltd','IN',NULL,'2026-10-11','2026-10-11 14:02:10+00','2026-10-11 14:02:30+00'),
 ('IA-66-40-0098',2,'e-91c3','UPSERT','IMPORT_ALERT','FDA','3004521877','Acme Pharma Pvt Ltd','IN','["62GDY99"]','2026-10-11','2026-10-12 09:30:00+00','2026-10-12 09:30:20+00'),
 ('RC-2026-1187',3,'e-93aa','RETRACT','RECALL','FDA',NULL,NULL,NULL,NULL,NULL,'2026-10-13 08:00:00+00','2026-10-13 08:00:15+00');
-- the duplicate e-88f1 must be a no-op:
INSERT INTO fact_enforcement_action
 (action_id, action_version, event_id, operation, action_type, agency, fei_number, firm_name, country_code, effective_date, event_time) VALUES
 ('IA-66-40-0098',1,'e-88f1','UPSERT','IMPORT_ALERT','FDA','3004521877','Acme Pharma Pvt Ltd','IN','2026-10-11','2026-10-11 14:02:10+00')
ON CONFLICT (action_id, action_version) DO NOTHING;

-- ---------------------------------------------------------------- S5
INSERT INTO dim_customer VALUES ('cust_042','Sample Drug Maker GmbH');

INSERT INTO dim_watchlist_entry
 (watch_id, valid_from, customer_id, customer_supplier_ref, supplier_name_as_typed, country_as_typed, fei_number_as_typed, is_active, cdc_timestamp) VALUES
 (9912,'2026-10-14 09:20+00','cust_042','SUP-0071','Acme Pharma Unit-II Hyderabad','India',NULL,true,1760436000000);
