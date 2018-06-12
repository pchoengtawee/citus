-- By default Citus makes lots of connections in the background which fill up the log
-- By tweaking these settings you can make sure you only capture packets related to what
--   you're doing
ALTER SYSTEM SET citus.distributed_deadlock_detection_factor TO -1;
ALTER SYSTEM SET citus.recover_2pc_interval TO -1;
ALTER SYSTEM set citus.enable_statistics_collection TO false;
SELECT pg_reload_conf();

-- Add some helper functions for sending commands to mitmproxy

CREATE FUNCTION citus.mitmproxy(text) RETURNS TABLE(result text) AS $$
DECLARE
  command ALIAS FOR $1;
BEGIN
  CREATE TEMPORARY TABLE mitmproxy_command (command text) ON COMMIT DROP;
  CREATE TEMPORARY TABLE mitmproxy_result (res text) ON COMMIT DROP;

  INSERT INTO mitmproxy_command VALUES (command);

  EXECUTE format('COPY mitmproxy_command TO %L', current_setting('citus.mitmfifo'));
  EXECUTE format('COPY mitmproxy_result FROM %L', current_setting('citus.mitmfifo'));

  RETURN QUERY SELECT * FROM mitmproxy_result;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION citus.clear_network_traffic() RETURNS void AS $$
BEGIN
  PERFORM citus.mitmproxy('recorder.reset()');
  RETURN; -- return void
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION citus.dump_network_traffic(
  normalize_shards bool default true,
  dump_unknown_messages bool default false
) RETURNS TABLE(conn int, from_client bool, message text) AS $$
DECLARE
  normalize_param text := CASE WHEN normalize_shards THEN 'True' ELSE 'False' END;
  dump_param text := CASE WHEN dump_unknown_messages THEN 'True' ELSE 'False' END;
  query text := format(
	'recorder.dump(normalize_shards=%s,dump_unknown_messages=%s)',
	normalize_param, dump_param);
BEGIN
  CREATE TEMPORARY TABLE mitmproxy_command (command text) ON COMMIT DROP;
  CREATE TEMPORARY TABLE mitmproxy_result (
    conn int, from_client bool, message text
  ) ON COMMIT DROP;

  INSERT INTO mitmproxy_command VALUES (query);

  EXECUTE format('COPY mitmproxy_command TO %L', current_setting('citus.mitmfifo'));
  EXECUTE format('COPY mitmproxy_result FROM %L', current_setting('citus.mitmfifo'));

  RETURN QUERY SELECT * FROM mitmproxy_result;
END;
$$ LANGUAGE plpgsql;
