test_run = require('test_run').new()
REPLICASET_1 = { 'storage_1_a', 'storage_1_b' }
REPLICASET_2 = { 'storage_2_a', 'storage_2_b' }
test_run:create_cluster(REPLICASET_1, 'storage')
test_run:create_cluster(REPLICASET_2, 'storage')
util = require('util')
util.wait_master(test_run, REPLICASET_1, 'storage_1_a')
util.wait_master(test_run, REPLICASET_2, 'storage_2_a')
util.map_evals(test_run, {REPLICASET_1, REPLICASET_2}, 'bootstrap_storage(\'memtx\')')

_ = test_run:switch('storage_2_a')
vshard.storage.rebalancer_disable()
_ = test_run:switch('storage_1_a')
box.cfg.read_only
ok = nil
err = nil
function on_master_enable() box.space.test:replace{1, 1} end
-- Test, that in disable trigger already can not write.
function on_master_disable() ok, err = pcall(box.space.test.replace, box.space.test, {2, 2}) end
vshard.storage.on_master_enable(on_master_enable)
vshard.storage.on_master_disable(on_master_disable)
box.space.test:select{}

_ = test_run:switch('storage_1_b')
box.cfg.read_only
ok, err = pcall(box.schema.create_space, 'test3')
assert(not ok and err.code == box.error.READONLY)
fiber = require('fiber')
function on_master_enable() box.space.test:replace{3, 3} end
function on_master_disable() if not box.cfg.read_only then box.space.test:replace{4, 4} end end
vshard.storage.on_master_enable(on_master_enable)
vshard.storage.on_master_disable(on_master_disable)
-- Yes, there is no 3 or 4, because a trigger on disable always
-- works in readonly.
box.space.test:select{}

-- Check that after master change the read_only is updated, and
-- that triggers on master role switch can change spaces.
cfg.sharding[util.replicasets[1]].replicas[util.name_to_uuid.storage_1_b].master = true
cfg.sharding[util.replicasets[1]].replicas[util.name_to_uuid.storage_1_a].master = false
vshard.storage.cfg(cfg, util.name_to_uuid.storage_1_b)
box.cfg.read_only
box.space.test:select{}

_ = test_run:switch('storage_1_a')
cfg.sharding[util.replicasets[1]].replicas[util.name_to_uuid.storage_1_b].master = true
cfg.sharding[util.replicasets[1]].replicas[util.name_to_uuid.storage_1_a].master = false
vshard.storage.cfg(cfg, util.name_to_uuid.storage_1_a)
box.cfg.read_only
assert(not ok and err.code == box.error.READONLY)
fiber = require('fiber')
while box.space.test:count() ~= 2 do fiber.sleep(0.1) end
box.space.test:select{}

_ = test_run:switch('storage_1_b')
box.space.test:drop()

_ = test_run:cmd("switch default")
test_run:drop_cluster(REPLICASET_2)
test_run:drop_cluster(REPLICASET_1)
