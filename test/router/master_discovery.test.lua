test_run = require('test_run').new()
REPLICASET_1 = { 'storage_1_a', 'storage_1_b' }
REPLICASET_2 = { 'storage_2_a', 'storage_2_b' }
test_run:create_cluster(REPLICASET_1, 'router')
test_run:create_cluster(REPLICASET_2, 'router')
util = require('util')
util.wait_master(test_run, REPLICASET_1, 'storage_1_a')
util.wait_master(test_run, REPLICASET_2, 'storage_2_a')
util.map_evals(test_run, {REPLICASET_1, REPLICASET_2}, 'bootstrap_storage(\'memtx\')')
util.push_rs_filters(test_run)
_ = test_run:cmd("create server router_1 with script='router/router_1.lua'")
_ = test_run:cmd("start server router_1")

--
-- gh-75: automatic master discovery on router.
--

_ = test_run:switch("router_1")
util = require('util')
vshard.router.bootstrap()

for _, rs in pairs(cfg.sharding) do                                             \
    for _, r in pairs(rs.replicas) do                                           \
        r.master = nil                                                          \
    end                                                                         \
end                                                                             \

function enable_auto_masters()                                                  \
    for _, rs in pairs(cfg.sharding) do                                         \
        rs.master = 'auto'                                                      \
    end                                                                         \
    vshard.router.cfg(cfg)                                                      \
end

function disable_auto_masters()                                                 \
    for _, rs in pairs(cfg.sharding) do                                         \
        rs.master = nil                                                         \
    end                                                                         \
    vshard.router.cfg(cfg)                                                      \
end

-- But do not forget the buckets. Otherwise bucket discovery will establish
-- the connections instead of external requests.
function forget_masters()                                                       \
    disable_auto_masters()                                                      \
    enable_auto_masters()                                                       \
end

function check_all_masters_found()                                              \
    for _, rs in pairs(vshard.router.static.replicasets) do                     \
        if not rs.master then                                                   \
            vshard.router.master_search_wakeup()                                \
            return false                                                        \
        end                                                                     \
    end                                                                         \
    return true                                                                 \
end

function check_master_for_replicaset(rs_id, master_name)                        \
    local rs_uuid = util.replicasets[rs_id]                                     \
    local master_uuid = util.name_to_uuid[master_name]                          \
    local master = vshard.router.static.replicasets[rs_uuid].master             \
    if not master or master.uuid ~= master_uuid then                            \
        vshard.router.master_search_wakeup()                                    \
        return false                                                            \
    end                                                                         \
    return true                                                                 \
end

function check_all_buckets_found()                                              \
    if vshard.router.info().bucket.unknown == 0 then                            \
        return true                                                             \
    end                                                                         \
    vshard.router.discovery_wakeup()                                            \
    return false                                                                \
end

master_search_helper_f = nil
function aggressive_master_search_f()                                           \
    while true do                                                               \
        vshard.router.master_search_wakeup()                                    \
        fiber.sleep(0.001)                                                      \
    end                                                                         \
end

function start_aggressive_master_search()                                       \
    assert(master_search_helper_f == nil)                                       \
    master_search_helper_f = fiber.new(aggressive_master_search_f)              \
    master_search_helper_f:set_joinable(true)                                   \
end

function stop_aggressive_master_search()                                        \
    assert(master_search_helper_f ~= nil)                                       \
    master_search_helper_f:cancel()                                             \
    master_search_helper_f:join()                                               \
    master_search_helper_f = nil                                                \
end

--
-- Simulate the first cfg when no masters are known.
--
forget_masters()
assert(vshard.router.static.master_search_fiber ~= nil)
test_run:wait_cond(check_all_masters_found)
test_run:wait_cond(check_all_buckets_found)

--
-- Change master and see how router finds it again.
--
test_run:switch('storage_1_a')
replicas = cfg.sharding[util.replicasets[1]].replicas
replicas[util.name_to_uuid.storage_1_a].master = false
replicas[util.name_to_uuid.storage_1_b].master = true
vshard.storage.cfg(cfg, instance_uuid)

test_run:switch('storage_1_b')
replicas = cfg.sharding[util.replicasets[1]].replicas
replicas[util.name_to_uuid.storage_1_a].master = false
replicas[util.name_to_uuid.storage_1_b].master = true
vshard.storage.cfg(cfg, instance_uuid)

test_run:switch('router_1')
big_timeout = 1000000
opts_big_timeout = {timeout = big_timeout}
test_run:wait_cond(function()                                                   \
    return check_master_for_replicaset(1, 'storage_1_b')                        \
end)
vshard.router.callrw(1501, 'echo', {1}, opts_big_timeout)

test_run:switch('storage_1_b')
assert(echo_count == 1)
echo_count = 0

--
-- Revert the master back.
--
test_run:switch('storage_1_a')
replicas = cfg.sharding[util.replicasets[1]].replicas
replicas[util.name_to_uuid.storage_1_a].master = true
replicas[util.name_to_uuid.storage_1_b].master = false
vshard.storage.cfg(cfg, instance_uuid)

test_run:switch('storage_1_b')
replicas = cfg.sharding[util.replicasets[1]].replicas
replicas[util.name_to_uuid.storage_1_a].master = true
replicas[util.name_to_uuid.storage_1_b].master = false
vshard.storage.cfg(cfg, instance_uuid)

test_run:switch('router_1')
test_run:wait_cond(function()                                                   \
    return check_master_for_replicaset(1, 'storage_1_a')                        \
end)

--
-- Call tries to wait for master if has enough time left.
--
start_aggressive_master_search()

forget_masters()
vshard.router.callrw(1501, 'echo', {1}, opts_big_timeout)

forget_masters()
-- XXX: this should not depend on master so much. RO requests should be able to
-- go to replicas.
vshard.router.callro(1501, 'echo', {1}, opts_big_timeout)

forget_masters()
vshard.router.route(1501):callrw('echo', {1}, opts_big_timeout)

forget_masters()
-- XXX: the same as above - should not really wait for master. Regardless of it
-- being auto or not.
vshard.router.route(1501):callro('echo', {1}, opts_big_timeout)

stop_aggressive_master_search()

test_run:switch('storage_1_a')
assert(echo_count == 4)
echo_count = 0

--
-- Old replicaset objects stop waiting for master when search is disabled.
--

-- Turn off masters on the first replicaset.
replicas = cfg.sharding[util.replicasets[1]].replicas
replicas[util.name_to_uuid.storage_1_a].master = false
vshard.storage.cfg(cfg, instance_uuid)

test_run:switch('storage_1_b')
replicas = cfg.sharding[util.replicasets[1]].replicas
replicas[util.name_to_uuid.storage_1_a].master = false
vshard.storage.cfg(cfg, instance_uuid)

-- Try to make RW and RO requests but then turn of the auto search.
test_run:switch('router_1')
forget_masters()
f1 = fiber.create(function()                                                    \
    fiber.self():set_joinable(true)                                             \
    return vshard.router.callrw(1501, 'echo', {1}, opts_big_timeout)            \
end)
-- XXX: should not really wait for master since this is an RO request. It could
-- use a replica.
f2 = fiber.create(function()                                                    \
    fiber.self():set_joinable(true)                                             \
    return vshard.router.callro(1501, 'echo', {1}, opts_big_timeout)            \
end)
fiber.sleep(0.01)
disable_auto_masters()
f1:join()
f2:join()

--
-- Multiple masters logging.
--
test_run:switch('storage_1_a')
replicas = cfg.sharding[util.replicasets[1]].replicas
replicas[util.name_to_uuid.storage_1_a].master = true
vshard.storage.cfg(cfg, instance_uuid)

test_run:switch('storage_1_b')
replicas = cfg.sharding[util.replicasets[1]].replicas
replicas[util.name_to_uuid.storage_1_b].master = true
vshard.storage.cfg(cfg, instance_uuid)

test_run:switch('router_1')
forget_masters()
start_aggressive_master_search()
test_run:wait_log('router_1', 'Found more than one master', nil, 10)
stop_aggressive_master_search()

--
-- Async request won't wait for master. Otherwise it would need to wait, which
-- is not async behaviour. The timeout should be ignored.
--
do                                                                              \
    forget_masters()                                                            \
    return vshard.router.callrw(1501, 'echo', {1}, {                            \
        is_async = true, timeout = big_timeout                                  \
    })                                                                          \
end

_ = test_run:switch("default")
_ = test_run:cmd("stop server router_1")
_ = test_run:cmd("cleanup server router_1")
test_run:drop_cluster(REPLICASET_1)
test_run:drop_cluster(REPLICASET_2)
_ = test_run:cmd('clear filter')