SELECT citus.mitmproxy('conn.allow()');

SET citus.shard_count = 2; -- one per worker

CREATE TABLE index_test(id int, value_1 int, value_2 int);
SELECT create_distributed_table('index_test', 'id');

-- kill the connection when create command is issued
SELECT citus.mitmproxy('conn.onQuery(query="CREATE").kill()');
SELECT citus.clear_network_traffic();

CREATE INDEX CONCURRENTLY idx_index_test ON index_test(id, value_1);

SELECT citus.dump_network_traffic();
SELECT citus.mitmproxy('conn.allow()');

DROP TABLE index_test;

CREATE TABLE index_test(id int, value_1 int, value_2 int);
SELECT create_reference_table('index_test');

-- kill the connection when create command is issued
SELECT citus.mitmproxy('conn.onQuery(query="CREATE").kill()');
SELECT citus.clear_network_traffic();

CREATE INDEX CONCURRENTLY idx_index_test ON index_test(id, value_1);

SELECT citus.dump_network_traffic();
SELECT citus.mitmproxy('conn.allow()');

DROP TABLE index_test;

