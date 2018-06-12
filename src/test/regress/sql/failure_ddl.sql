-- 
-- Test DDL command propagation failures 
-- Different dimensions we're testing:
--    Replication factor, 1PC-2PC, sequential-parallel modes
-- 


CREATE SCHEMA ddl_failure;

SET search_path TO 'ddl_failure';

-- we don't want to see the prepared transaction numbers in the warnings
SET client_min_messages TO ERROR;

SELECT citus.mitmproxy('conn.allow()');

SET citus.next_shard_id TO 100800;

-- we'll start with replication factor 1, 1PC and parallel mode
SET citus.multi_shard_commit_protocol TO '1pc';
SET citus.shard_count = 4;
SET citus.shard_replication_factor = 1;

CREATE TABLE test_table (key int, value int);
SELECT create_distributed_table('test_table', 'key');

-- in the first test, kill just in the first 
-- response we get from the worker
SELECT citus.mitmproxy('conn.onAuthenticationOk().kill()');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- cancel just in the first 
-- response we get from the worker
SELECT citus.mitmproxy('conn.onAuthenticationOk().cancel(' ||  pg_backend_pid() || ')');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- kill as soon as the coordinator sends begin
SELECT citus.mitmproxy('conn.onQuery(query="^BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED").kill()');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- cancel as soon as the coordinator sends begin
SELECT citus.mitmproxy('conn.onQuery(query="^BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED").cancel(' ||  pg_backend_pid() || ')');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- kill as soon as the coordinator sends worker_apply_shard_ddl_command
SELECT citus.mitmproxy('conn.onQuery(query="worker_apply_shard_ddl_command").kill()');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');

-- show that we've never commited the changes
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- cance; as soon as the coordinator sends worker_apply_shard_ddl_command
SELECT citus.mitmproxy('conn.onQuery(query="worker_apply_shard_ddl_command").cancel(' ||  pg_backend_pid() || ')');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');

-- show that we've never commited the changes
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- kill as soon as the coordinator sends COMMIT
SELECT citus.mitmproxy('conn.onQuery(query="COMMIT").kill()');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');

-- since we've killed the connection just after
-- the coordinator send the COMMIT, the command should not have
-- affected the distributed table and the shards
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- cancel as soon as the coordinator sends COMMIT
SELECT citus.mitmproxy('conn.onQuery(query="COMMIT").cancel(' ||  pg_backend_pid() || ')');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');

-- since we've cancelled the connection just after
-- the coordinator send the COMMIT, the command should not have
-- affected the distributed table and the shards
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- but now kill just after the worker sends response to 
-- COMMIT command, so we'll have lots of warnings but the command
-- should have been committed both on the distributed table and the placements
SELECT citus.mitmproxy('conn.onCommandComplete(command="COMMIT").kill()');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');

SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- now cancel just after the worker sends response to 
-- but Postgres doesn't accepts interrupts during COMMIT and ROLLBACK
-- so should not cancel at all, so not an effective test but adding in
-- case Citus messes up this behaviour
SELECT citus.mitmproxy('conn.onCommandComplete(command="COMMIT").cancel(' ||  pg_backend_pid() || ')');
ALTER TABLE test_table DROP COLUMN new_column;
SELECT citus.mitmproxy('conn.allow()');

-- the remaining tests rely on table having new_column
ALTER TABLE test_table ADD COLUMN new_column INT;

-- finally, test failing on ROLLBACK with 1CPC

-- fail just after the coordinator sends the ROLLBACK
-- so the command can be rollbacked
SELECT citus.mitmproxy('conn.onQuery(query="ROLLBACK").kill()');
BEGIN;
ALTER TABLE test_table DROP COLUMN new_column;
ROLLBACK;
SELECT citus.mitmproxy('conn.allow()');

-- now cancel just after the worker sends response to 
-- but Postgres doesn't accepts interrupts during COMMIT and ROLLBACK
-- so should not cancel at all, so not an effective test but adding in
-- case Citus messes up this behaviour
SELECT citus.mitmproxy('conn.onQuery(query="ROLLBACK").cancel(' ||  pg_backend_pid() || ')');
BEGIN;
ALTER TABLE test_table DROP COLUMN new_column;
ROLLBACK;
SELECT citus.mitmproxy('conn.allow()');

-- but now kill just after the worker sends response to 
-- ROLLBACK command, so we'll have lots of warnings but the command
-- should have been rollbacked both on the distributed table and the placements
SELECT citus.mitmproxy('conn.onCommandComplete(command="ROLLBACK").kill()');
BEGIN;
ALTER TABLE test_table DROP COLUMN new_column;
ROLLBACK;
SELECT citus.mitmproxy('conn.allow()');

SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- now, lets test with 2PC with 
SET citus.multi_shard_commit_protocol TO '2pc';

-- in the first test, kill just in the first 
-- response we get from the worker
SELECT citus.mitmproxy('conn.onAuthenticationOk().kill()');
ALTER TABLE test_table DROP COLUMN new_column;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- cancel just in the first 
-- response we get from the worker
SELECT citus.mitmproxy('conn.onAuthenticationOk().cancel(' ||  pg_backend_pid() || ')');
ALTER TABLE test_table DROP COLUMN new_column;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- kill as soon as the coordinator sends begin
SELECT citus.mitmproxy('conn.onQuery(query="^BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED").kill()');
ALTER TABLE test_table DROP COLUMN new_column;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- cancel as soon as the coordinator sends begin
SELECT citus.mitmproxy('conn.onQuery(query="^BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED").cancel(' ||  pg_backend_pid() || ')');
ALTER TABLE test_table DROP COLUMN new_column;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- kill as soon as the coordinator sends worker_apply_shard_ddl_command
SELECT citus.mitmproxy('conn.onQuery(query="worker_apply_shard_ddl_command").kill()');
ALTER TABLE test_table DROP COLUMN new_column;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- cancel as soon as the coordinator sends worker_apply_shard_ddl_command
SELECT citus.mitmproxy('conn.onQuery(query="worker_apply_shard_ddl_command").cancel(' ||  pg_backend_pid() || ')');
ALTER TABLE test_table DROP COLUMN new_column;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;


-- killing on PREPARE should be fine, everything should be rollbacked
SELECT citus.mitmproxy('conn.onCommandComplete(command="PREPARE TRANSACTION").kill()');
ALTER TABLE test_table DROP COLUMN new_column;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- we should be able to revocer the transaction and
-- see that the command is rollbacked
SELECT recover_prepared_transactions();
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;


-- cancelling on PREPARE should be fine, everything should be rollbacked
SELECT citus.mitmproxy('conn.onCommandComplete(command="PREPARE TRANSACTION").cancel(' ||  pg_backend_pid() || ')');
ALTER TABLE test_table DROP COLUMN new_column;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- we should be able to revocer the transaction and
-- see that the command is rollbacked
SELECT recover_prepared_transactions();
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- killing on command complete of COMMIT PREPARE, we should see that the command succeeds
-- and all the workers committed
SELECT citus.mitmproxy('conn.onCommandComplete(command="COMMIT PREPARED").kill()');
ALTER TABLE test_table DROP COLUMN new_column;
SELECT citus.mitmproxy('conn.allow()');

SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- we shouldn't have any prepared transactions in the workers
SELECT recover_prepared_transactions();
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- kill as soon as the coordinator sends COMMIT
SELECT citus.mitmproxy('conn.onQuery(query="^COMMIT PREPARED").kill()');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');

-- some of the placements would be missing the new column
-- since we've not commited the prepared transactions
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- we should be able to revocer the transaction and
-- see that the command is committed
SELECT recover_prepared_transactions();
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- finally, test failing on ROLLBACK with 2CPC

-- fail just after the coordinator sends the ROLLBACK
-- so the command can be rollbacked
SELECT citus.mitmproxy('conn.onQuery(query="ROLLBACK").kill()');
BEGIN;
ALTER TABLE test_table DROP COLUMN new_column;
ROLLBACK;
SELECT citus.mitmproxy('conn.allow()');

-- ROLLBACK should have failed on the distributed table and the placements
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- but now kill just after the worker sends response to 
-- ROLLBACK command, so we'll have lots of warnings but the command
-- should have been rollbacked both on the distributed table and the placements
SELECT citus.mitmproxy('conn.onCommandComplete(command="ROLLBACK").kill()');
BEGIN;
ALTER TABLE test_table DROP COLUMN new_column;
ROLLBACK;
SELECT citus.mitmproxy('conn.allow()');

-- make sure that the transaction is rollbacked
SELECT recover_prepared_transactions();
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;


-- final set of tests with 2PC and replication factor = 2
SET citus.multi_shard_commit_protocol TO '2pc';
SET citus.shard_count = 4;
SET citus.shard_replication_factor = 2;

-- re-create the table with replication factor 2
DROP TABLE test_table;
CREATE TABLE test_table (key int, value int);
SELECT create_distributed_table('test_table', 'key');

-- in the first test, kill just in the first 
-- response we get from the worker
SELECT citus.mitmproxy('conn.onAuthenticationOk().kill()');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- cancel just in the first 
-- response we get from the worker
SELECT citus.mitmproxy('conn.onAuthenticationOk().cancel(' ||  pg_backend_pid() || ')');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- kill as soon as the coordinator sends begin
SELECT citus.mitmproxy('conn.onQuery(query="^BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED").kill()');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- cancel as soon as the coordinator sends begin
SELECT citus.mitmproxy('conn.onQuery(query="^BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED").cancel(' ||  pg_backend_pid() || ')');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- kill as soon as the coordinator sends worker_apply_shard_ddl_command
SELECT citus.mitmproxy('conn.onQuery(query="worker_apply_shard_ddl_command").kill()');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- cancel as soon as the coordinator sends worker_apply_shard_ddl_command
SELECT citus.mitmproxy('conn.onQuery(query="worker_apply_shard_ddl_command").cancel(' ||  pg_backend_pid() || ')');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;

-- killing on PREPARE should be fine, everything should be rollbacked
SELECT citus.mitmproxy('conn.onCommandComplete(command="PREPARE TRANSACTION").kill()');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');

SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- we should be able to revocer the transaction and
-- see that the command is rollbacked
SELECT recover_prepared_transactions();
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- killing on command complete of COMMIT PREPARE, we should see that the command succeeds
-- and all the workers committed
SELECT citus.mitmproxy('conn.onCommandComplete(command="COMMIT PREPARED").kill()');
ALTER TABLE test_table ADD COLUMN new_column INT;
SELECT citus.mitmproxy('conn.allow()');

SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- we shouldn't have any prepared transactions in the workers
SELECT recover_prepared_transactions();
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- kill as soon as the coordinator sends COMMIT
SELECT citus.mitmproxy('conn.onQuery(query="^COMMIT PREPARED").kill()');
ALTER TABLE test_table DROP COLUMN new_column;
SELECT citus.mitmproxy('conn.allow()');

-- some of the placements would be missing the new column
-- since we've not commited the prepared transactions
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- we should be able to revocer the transaction and
-- see that the command is committed
SELECT recover_prepared_transactions();
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- finally, test failing on ROLLBACK with 2CPC

-- fail just after the coordinator sends the ROLLBACK
-- so the command can be rollbacked
SELECT citus.mitmproxy('conn.onQuery(query="ROLLBACK").kill()');
BEGIN;
ALTER TABLE test_table ADD COLUMN new_column INT;
ROLLBACK;
SELECT citus.mitmproxy('conn.allow()');

-- ROLLBACK should have failed on the distributed table and the placements
SELECT count(*) FROM public.table_attrs where relid = 'test_table'::regclass;
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

-- but now kill just after the worker sends response to 
-- ROLLBACK command, so we'll have lots of warnings but the command
-- should have been rollbacked both on the distributed table and the placements
SELECT citus.mitmproxy('conn.onCommandComplete(command="ROLLBACK").kill()');
BEGIN;
ALTER TABLE test_table ADD COLUMN new_column INT;
ROLLBACK;
SELECT citus.mitmproxy('conn.allow()');

-- make sure that the transaction is rollbacked
SELECT recover_prepared_transactions();
SELECT run_command_on_placements('test_table', $$SELECT count(*) FROM public.table_attrs where relid = '%s'::regclass$$) ORDER BY 1;

SET search_path TO 'public';
DROP SCHEMA ddl_failure CASCADE;
