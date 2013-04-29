-------------------------------------------------------------------------------
-- This is the analog of the 'main' function when invoking qless directly, as
-- apposed to for use within another library
-------------------------------------------------------------------------------
local QlessAPI = {}

-- Return json for the job identified by the provided jid. If the job is not
-- present, then `nil` is returned
function QlessAPI.get(now, jid)
    local data = Qless.job(jid):data()
    if not data then
        return nil
    end
    return cjson.encode(data)
end

-- Public access
QlessAPI['config.get'] = function(now, key)
    return cjson.encode(Qless.config.get(key))
end

QlessAPI['config.set'] = function(now, key, value)
    return Qless.config.set(key, value)
end

-- Unset a configuration option
QlessAPI['config.unset'] = function(now, key)
    return Qless.config.unset(key)
end

-- Get information about a queue or queues
QlessAPI.queues = function(now, queue)
    return cjson.encode(Qless.queues(now, queue))
end

QlessAPI.complete = function(now, jid, worker, queue, data, ...)
    return Qless.job(jid):complete(now, worker, queue, data, unpack(arg))
end

QlessAPI.failed = function(now, group, start, limit)
    return cjson.encode(Qless.failed(group, start, limit))
end

QlessAPI.fail = function(now, jid, worker, group, message, data)
    return Qless.job(jid):fail(now, worker, group, message, data)
end

QlessAPI.jobs = function(now, state, ...)
    return Qless.jobs(now, state, unpack(arg))
end

QlessAPI.retry = function(now, jid, queue, worker, delay)
    return Qless.job(jid):retry(now, queue, worker, delay)
end

QlessAPI.depends = function(now, jid, command, ...)
    return Qless.job(jid):depends(command, unpack(arg))
end

QlessAPI.heartbeat = function(now, jid, worker, data)
    return Qless.job(jid):heartbeat(now, worker, data)
end

QlessAPI.workers = function(now, worker)
    return cjson.encode(Qless.workers(now, worker))
end

QlessAPI.track = function(now, command, jid)
    return cjson.encode(Qless.track(now, command, jid))
end

QlessAPI.tag = function(now, command, ...)
    return cjson.encode(Qless.tag(now, command, unpack(arg)))
end

QlessAPI.stats = function(now, queue, date)
    return cjson.encode(Qless.queue(queue):stats(now, date))
end

QlessAPI.priority = function(now, jid, priority)
    return Qless.job(jid):priority(priority)
end

QlessAPI.peek = function(now, queue, count)
    local jids = Qless.queue(queue):peek(now, count)
    local response = {}
    for i, jid in ipairs(jids) do
        table.insert(response, Qless.job(jid):data())
    end
    return cjson.encode(response)
end

QlessAPI.pop = function(now, queue, worker, count)
    local jids = Qless.queue(queue):pop(now, worker, count)
    local response = {}
    for i, jid in ipairs(jids) do
        table.insert(response, Qless.job(jid):data())
    end
    return cjson.encode(response)
end

QlessAPI.pause = function(now, ...)
    return Qless.pause(unpack(arg))
end

QlessAPI.unpause = function(now, ...)
    return Qless.unpause(unpack(arg))
end

QlessAPI.cancel = function(now, ...)
    return Qless.cancel(unpack(arg))
end

QlessAPI.put = function(now, queue, jid, klass, data, delay, ...)
    return Qless.queue(queue):put(now, jid, klass, data, delay, unpack(arg))
end

QlessAPI.unfail = function(now, queue, group, count)
    return Qless.queue(queue):unfail(now, group, count)
end

-- Recurring job stuff
QlessAPI.recur = function(now, queue, jid, klass, data, spec, ...)
    return Qless.queue(queue):recur(now, jid, klass, data, spec, unpack(arg))
end

QlessAPI.unrecur = function(now, jid)
    return Qless.recurring(jid):unrecur()
end

QlessAPI['recur.get'] = function(now, jid)
    return cjson.encode(Qless.recurring(jid):data())
end

QlessAPI['recur.update'] = function(now, jid, ...)
    return Qless.recurring(jid):update(unpack(arg))
end

QlessAPI['recur.tag'] = function(now, jid, ...)
    return Qless.recurring(jid):tag(unpack(arg))
end

QlessAPI['recur.untag'] = function(now, jid, ...)
    return Qless.recurring(jid):untag(unpack(arg))
end

QlessAPI.length = function(now, queue)
    return Qless.queue(queue):length()
end

-------------------------------------------------------------------------------
-- Function lookup
-------------------------------------------------------------------------------

-- None of the qless function calls accept keys
if #KEYS > 0 then erorr('No Keys should be provided') end

-- The first argument must be the function that we intend to call, and it must
-- exist
local command_name = assert(table.remove(ARGV, 1), 'Must provide a command')
local command      = assert(
    QlessAPI[command_name], 'Unknown command ' .. command_name)

-- The second argument should be the current time from the requesting client
local now          = tonumber(table.remove(ARGV, 1))
local now          = assert(
    now, 'Arg "now" missing or not a number: ' .. (now or 'nil'))

return command(now, unpack(ARGV))