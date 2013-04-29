-------------------------------------------------------------------------------
-- Queue class
-------------------------------------------------------------------------------

-- Stats(0, queue, date)
-- ---------------------
-- Return the current statistics for a given queue on a given date. The
-- results are returned are a JSON blob:
--
--
--  {
--      # These are unimplemented as of yet
--      'failed': 3,
--      'retries': 5,
--      'wait' : {
--          'total'    : ...,
--          'mean'     : ...,
--          'variance' : ...,
--          'histogram': [
--              ...
--          ]
--      }, 'run': {
--          'total'    : ...,
--          'mean'     : ...,
--          'variance' : ...,
--          'histogram': [
--              ...
--          ]
--      }
--  }
--
-- The histogram's data points are at the second resolution for the first
-- minute, the minute resolution for the first hour, the 15-minute resolution
-- for the first day, the hour resolution for the first 3 days, and then at
-- the day resolution from there on out. The `histogram` key is a list of
-- those values.
--
-- Args:
--    1) queue
--    2) time
function QlessQueue:stats(now, date)
    date = assert(tonumber(date),
        'Stats(): Arg "date" missing or not a number: '.. (date or 'nil'))

    -- The bin is midnight of the provided day
    -- 24 * 60 * 60 = 86400
    local bin = date - (date % 86400)

    -- This a table of all the keys we want to use in order to produce a histogram
    local histokeys = {
        's0','s1','s2','s3','s4','s5','s6','s7','s8','s9','s10','s11','s12','s13','s14','s15','s16','s17','s18','s19','s20','s21','s22','s23','s24','s25','s26','s27','s28','s29','s30','s31','s32','s33','s34','s35','s36','s37','s38','s39','s40','s41','s42','s43','s44','s45','s46','s47','s48','s49','s50','s51','s52','s53','s54','s55','s56','s57','s58','s59',
        'm1','m2','m3','m4','m5','m6','m7','m8','m9','m10','m11','m12','m13','m14','m15','m16','m17','m18','m19','m20','m21','m22','m23','m24','m25','m26','m27','m28','m29','m30','m31','m32','m33','m34','m35','m36','m37','m38','m39','m40','m41','m42','m43','m44','m45','m46','m47','m48','m49','m50','m51','m52','m53','m54','m55','m56','m57','m58','m59',
        'h1','h2','h3','h4','h5','h6','h7','h8','h9','h10','h11','h12','h13','h14','h15','h16','h17','h18','h19','h20','h21','h22','h23',
        'd1','d2','d3','d4','d5','d6'
    }

    local mkstats = function(name, bin, queue)
        -- The results we'll be sending back
        local results = {}
        
        local count, mean, vk = unpack(redis.call('hmget', 'ql:s:' .. name .. ':' .. bin .. ':' .. queue, 'total', 'mean', 'vk'))
        
        count = tonumber(count) or 0
        mean  = tonumber(mean) or 0
        vk    = tonumber(vk)
        
        results.count     = count or 0
        results.mean      = mean  or 0
        results.histogram = {}

        if not count then
            results.std = 0
        else
            if count > 1 then
                results.std = math.sqrt(vk / (count - 1))
            else
                results.std = 0
            end
        end

        local histogram = redis.call('hmget', 'ql:s:' .. name .. ':' .. bin .. ':' .. queue, unpack(histokeys))
        for i=1,#histokeys do
            table.insert(results.histogram, tonumber(histogram[i]) or 0)
        end
        return results
    end

    local retries, failed, failures = unpack(redis.call('hmget', 'ql:s:stats:' .. bin .. ':' .. self.name, 'retries', 'failed', 'failures'))
    return {
        retries  = tonumber(retries  or 0),
        failed   = tonumber(failed   or 0),
        failures = tonumber(failures or 0),
        wait     = mkstats('wait', bin, self.name),
        run      = mkstats('run' , bin, self.name)
    }
end

-- Instantiate any recurring jobs that are ready
function QlessQueue:update_recurring_jobs(now, count)
    local key = 'ql:q:' .. self.name
    -- This is how many jobs we've moved so far
    local moved = 0
    -- These are the recurring jobs that need work
    local r = redis.call('zrangebyscore', key .. '-recur', 0, now, 'LIMIT', 0, count)
    for index, jid in ipairs(r) do
        -- For each of the jids that need jobs scheduled, first
        -- get the last time each of them was run, and then increment
        -- it by its interval. While this time is less than now,
        -- we need to keep putting jobs on the queue
        local klass, data, priority, tags, retries, interval = unpack(redis.call('hmget', 'ql:r:' .. jid, 'klass', 'data', 'priority', 'tags', 'retries', 'interval'))
        local _tags = cjson.decode(tags)
        
        -- We're saving this value so that in the history, we can accurately 
        -- reflect when the job would normally have been scheduled
        local score = math.floor(tonumber(redis.call('zscore', key .. '-recur', jid)))
        while (score <= now) and (moved < count) do
            local count = redis.call('hincrby', 'ql:r:' .. jid, 'count', 1)
            moved = moved + 1
            
            -- Add this job to the list of jobs tagged with whatever tags were supplied
            for i, tag in ipairs(_tags) do
                redis.call('zadd', 'ql:t:' .. tag, now, jid .. '-' .. count)
                redis.call('zincrby', 'ql:tags', 1, tag)
            end
            
            -- First, let's save its data
            redis.call('hmset', 'ql:j:' .. jid .. '-' .. count,
                'jid'      , jid .. '-' .. count,
                'klass'    , klass,
                'data'     , data,
                'priority' , priority,
                'tags'     , tags,
                'state'    , 'waiting',
                'worker'   , '',
                'expires'  , 0,
                'queue'    , self.name,
                'retries'  , retries,
                'remaining', retries,
                'history'  , cjson.encode({{
                    -- The job was essentially put in this queue at this time,
                    -- and not the current time
                    q     = self.name,
                    put   = math.floor(score)
                }}))
            
            -- Now, if a delay was provided, and if it's in the future,
            -- then we'll have to schedule it. Otherwise, we're just
            -- going to add it to the work queue.
            redis.call('zadd', key .. '-work', priority - (score / 10000000000), jid .. '-' .. count)
            
            redis.call('zincrby', key .. '-recur', interval, jid)
            score = score + interval
        end
    end
end

function QlessQueue:check_lost_locks(now, count, execute)
    local key = 'ql:q:' .. self.name
    -- zadd is a list of arguments that we'll be able to use to
    -- insert into the work queue
    local zadd = {}
    local r = redis.call('zrangebyscore', key .. '-scheduled', 0, now, 'LIMIT', 0, count)
    for index, jid in ipairs(r) do
        -- With these in hand, we'll have to go out and find the 
        -- priorities of these jobs, and then we'll insert them
        -- into the work queue and then when that's complete, we'll
        -- remove them from the scheduled queue
        table.insert(zadd, tonumber(redis.call('hget', 'ql:j:' .. jid, 'priority') or 0))
        table.insert(zadd, jid)
        -- We should also update them to have the state 'waiting'
        -- instead of 'scheduled'
        redis.call('hset', 'ql:j:' .. jid, 'state', 'waiting')
    end
    
    if #zadd > 0 then
        -- Now add these to the work list, and then remove them
        -- from the scheduled list
        redis.call('zadd', key .. '-work', unpack(zadd))
        redis.call('zrem', key .. '-scheduled', unpack(r))
    end
    
    -- And now we should get up to the maximum number of requested
    -- work items from the work queue.
    local keys = {}
    for index, jid in ipairs(redis.call('zrevrange', key .. '-work', 0, count - 1)) do
        table.insert(keys, jid)
    end
    return keys
end

-- This script takes the name of the queue and then checks
-- for any expired locks, then inserts any scheduled items
-- that are now valid, and lastly returns any work items 
-- that can be handed over.
--
-- Keys:
--    1) queue name
-- Args:
--    1) the number of items to return
--    2) the current time
function QlessQueue:peek(now, count)
    count = assert(tonumber(count),
        'Peek(): Arg "count" missing or not a number: ' .. (count or 'nil'))
    local key     = 'ql:q:' .. self.name
    local count   = assert(tonumber(count) , 'Peek(): Arg "count" missing or not a number: ' .. (count or 'nil'))

    -- These are the ids that we're going to return
    local keys = {}

    -- Iterate through all the expired locks and add them to the list
    -- of keys that we'll return
    for index, jid in ipairs(redis.call('zrangebyscore', key .. '-locks', 0, now, 'LIMIT', 0, count)) do
        table.insert(keys, jid)
    end

    -- If we still need jobs in order to meet demand, then we should
    -- look for all the recurring jobs that need jobs run
    if #keys < count then
        self:update_recurring_jobs(now, count - #keys)
    end

    -- Now we've checked __all__ the locks for this queue the could
    -- have expired, and are no more than the number requested. If
    -- we still need values in order to meet the demand, then we 
    -- should check if any scheduled items, and if so, we should 
    -- insert them to ensure correctness when pulling off the next
    -- unit of work.
    if #keys < count then
        local locks = self:check_lost_locks(now, count - #keys)
        for k, v in ipairs(locks) do table.insert(keys, v) end
    end

    -- Alright, now the `keys` table is filled with all the job
    -- ids which we'll be returning. Now we need to get the 
    -- metadeata about each of these, update their metadata to
    -- reflect which worker they're on, when the lock expires, 
    -- etc., add them to the locks queue and then we have to 
    -- finally return a list of json blobs
    return keys
end

-- This script takes the name of the queue and then checks
-- for any expired locks, then inserts any scheduled items
-- that are now valid, and lastly returns any work items 
-- that can be handed over.
--
-- Keys:
--    1) queue name
-- Args:
--    1) worker name
--    2) the number of items to return
--    3) the current time
function QlessQueue:pop(now, worker, count)
    local key     = 'ql:q:' .. self.name
    assert(worker, 'Pop(): Arg "worker" missing')
    count = assert(tonumber(count),
        'Pop(): Arg "count" missing or not a number: ' .. (count or 'nil'))

    -- We should find the heartbeat interval for this queue
    -- heartbeat
    local expires   = now + tonumber(
        Qless.config.get(self.name .. '-heartbeat') or
        Qless.config.get('heartbeat', 60))

    -- The bin is midnight of the provided day
    -- 24 * 60 * 60 = 86400
    local bin = now - (now % 86400)

    -- These are the ids that we're going to return
    local keys = {}

    -- Make sure we this worker to the list of seen workers
    redis.call('zadd', 'ql:workers', now, worker)

    if redis.call('sismember', 'ql:paused_queues', self.name) == 1 then
      return {}
    end

    -- Iterate through all the expired locks and add them to the list
    -- of keys that we'll return
    for index, jid in ipairs(redis.call('zrangebyscore', key .. '-locks', 0, now, 'LIMIT', 0, count)) do
        -- Remove this job from the jobs that the worker that was running it has
        local w = redis.call('hget', 'ql:j:' .. jid, 'worker')
        redis.call('zrem', 'ql:w:' .. w .. ':jobs', jid)

        -- Send a message to let the worker know that its lost its lock on the job
        local encoded = cjson.encode({
            jid    = jid,
            event  = 'lock lost',
            worker = w
        })
        redis.call('publish', w, encoded)
        redis.call('publish', 'log', encoded)
        
        -- For each of these, decrement their retries. If any of them
        -- have exhausted their retries, then we should mark them as
        -- failed.
        if redis.call('hincrby', 'ql:j:' .. jid, 'remaining', -1) < 0 then
            -- Now remove the instance from the schedule, and work queues for the queue it's in
            redis.call('zrem', 'ql:q:' .. self.name .. '-work', jid)
            redis.call('zrem', 'ql:q:' .. self.name .. '-locks', jid)
            redis.call('zrem', 'ql:q:' .. self.name .. '-scheduled', jid)
            
            local group = 'failed-retries-' .. self.name
            -- First things first, we should get the history
            local history = redis.call('hget', 'ql:j:' .. jid, 'history')
            
            -- Now, take the element of the history for which our provided worker is the worker, and update 'failed'
            history = cjson.decode(history or '[]')
            history[#history]['failed'] = now
            
            redis.call('hmset', 'ql:j:' .. jid, 'state', 'failed', 'worker', '',
                'expires', '', 'history', cjson.encode(history), 'failure', cjson.encode({
                    ['group']   = group,
                    ['message'] = 'Job exhausted retries in queue "' .. self.name .. '"',
                    ['when']    = now,
                    ['worker']  = history[#history]['worker']
                }))
            
            -- Add this type of failure to the list of failures
            redis.call('sadd', 'ql:failures', group)
            -- And add this particular instance to the failed types
            redis.call('lpush', 'ql:f:' .. group, jid)
            
            if redis.call('zscore', 'ql:tracked', jid) ~= false then
                redis.call('publish', 'failed', jid)
            end
        else
            table.insert(keys, jid)
            
            if redis.call('zscore', 'ql:tracked', jid) ~= false then
                redis.call('publish', 'stalled', jid)
            end
        end
    end
    -- Now we've checked __all__ the locks for this queue the could
    -- have expired, and are no more than the number requested.

    -- If we got any expired locks, then we should increment the
    -- number of retries for this stage for this bin
    redis.call('hincrby', 'ql:s:stats:' .. bin .. ':' .. self.name, 'retries', #keys)

    -- If we still need jobs in order to meet demand, then we should
    -- look for all the recurring jobs that need jobs run
    if #keys < count then
        self:update_recurring_jobs(now, count - #keys)
    end

    -- If we still need values in order to meet the demand, then we 
    -- should check if any scheduled items, and if so, we should 
    -- insert them to ensure correctness when pulling off the next
    -- unit of work.
    if #keys < count then    
        -- zadd is a list of arguments that we'll be able to use to
        -- insert into the work queue
        local zadd = {}
        local r = redis.call('zrangebyscore', key .. '-scheduled', 0, now, 'LIMIT', 0, (count - #keys))
        for index, jid in ipairs(r) do
            -- With these in hand, we'll have to go out and find the 
            -- priorities of these jobs, and then we'll insert them
            -- into the work queue and then when that's complete, we'll
            -- remove them from the scheduled queue
            table.insert(zadd, tonumber(redis.call('hget', 'ql:j:' .. jid, 'priority') or 0))
            table.insert(zadd, jid)
        end
        
        -- Now add these to the work list, and then remove them
        -- from the scheduled list
        if #zadd > 0 then
            redis.call('zadd', key .. '-work', unpack(zadd))
            redis.call('zrem', key .. '-scheduled', unpack(r))
        end
        
        -- And now we should get up to the maximum number of requested
        -- work items from the work queue.
        for index, jid in ipairs(redis.call('zrevrange', key .. '-work', 0, (count - #keys) - 1)) do
            table.insert(keys, jid)
        end
    end

    -- Alright, now the `keys` table is filled with all the job
    -- ids which we'll be returning. Now we need to get the 
    -- metadeata about each of these, update their metadata to
    -- reflect which worker they're on, when the lock expires, 
    -- etc., add them to the locks queue and then we have to 
    -- finally return a list of json blobs

    local response = {}
    local state
    local history
    for index, jid in ipairs(keys) do
        -- First, we should get the state and history of the item
        state, history = unpack(redis.call('hmget', 'ql:j:' .. jid, 'state', 'history'))
        
        history = cjson.decode(history or '{}')
        history[#history]['worker'] = worker
        history[#history]['popped'] = math.floor(now)
        
        ----------------------------------------------------------
        -- This is the massive stats update that we have to do
        ----------------------------------------------------------
        -- This is how long we've been waiting to get popped
        local waiting = math.floor(now) - history[#history]['put']
        -- Now we'll go through the apparently long and arduous process of update
        local count, mean, vk = unpack(redis.call('hmget', 'ql:s:wait:' .. bin .. ':' .. self.name, 'total', 'mean', 'vk'))
        count = count or 0
        if count == 0 then
            mean  = waiting
            vk    = 0
            count = 1
        else
            count = count + 1
            local oldmean = mean
            mean  = mean + (waiting - mean) / count
            vk    = vk + (waiting - mean) * (waiting - oldmean)
        end
        -- Now, update the histogram
        -- - `s1`, `s2`, ..., -- second-resolution histogram counts
        -- - `m1`, `m2`, ..., -- minute-resolution
        -- - `h1`, `h2`, ..., -- hour-resolution
        -- - `d1`, `d2`, ..., -- day-resolution
        waiting = math.floor(waiting)
        if waiting < 60 then -- seconds
            redis.call('hincrby', 'ql:s:wait:' .. bin .. ':' .. self.name, 's' .. waiting, 1)
        elseif waiting < 3600 then -- minutes
            redis.call('hincrby', 'ql:s:wait:' .. bin .. ':' .. self.name, 'm' .. math.floor(waiting / 60), 1)
        elseif waiting < 86400 then -- hours
            redis.call('hincrby', 'ql:s:wait:' .. bin .. ':' .. self.name, 'h' .. math.floor(waiting / 3600), 1)
        else -- days
            redis.call('hincrby', 'ql:s:wait:' .. bin .. ':' .. self.name, 'd' .. math.floor(waiting / 86400), 1)
        end     
        redis.call('hmset', 'ql:s:wait:' .. bin .. ':' .. self.name, 'total', count, 'mean', mean, 'vk', vk)
        ----------------------------------------------------------
        
        -- Add this job to the list of jobs handled by this worker
        redis.call('zadd', 'ql:w:' .. worker .. ':jobs', expires, jid)
        
        -- Update the jobs data, and add its locks, and return the job
        redis.call(
            'hmset', 'ql:j:' .. jid, 'worker', worker, 'expires', expires,
            'state', 'running', 'history', cjson.encode(history))
        
        redis.call('zadd', key .. '-locks', expires, jid)
        local job = redis.call(
            'hmget', 'ql:j:' .. jid, 'jid', 'klass', 'state', 'queue', 'worker', 'priority',
            'expires', 'retries', 'remaining', 'data', 'tags', 'history', 'failure')
        
        local tracked = redis.call('zscore', 'ql:tracked', jid) ~= false
        if tracked then
            redis.call('publish', 'popped', jid)
        end
        
        table.insert(response, jid)
    end

    if #keys > 0 then
        redis.call('zrem', key .. '-work', unpack(keys))
    end

    return response
end

-- Put(1, jid, klass, data, now, delay, [priority, p], [tags, t], [retries, r], [depends, '[...]'])
-- ----------------------------------------------------------------------------
-- This script takes the name of the queue and then the 
-- info about the work item, and makes sure that it's 
-- enqueued.
--
-- At some point, I'd like to able to provide functionality
-- that enables this to generate a unique ID for this piece
-- of work. As such, client libraries should not expose 
-- setting the id from the user, as this is an implementation
-- detail that's likely to change and users should not grow
-- to depend on it.
--
-- Args:
--    1) jid
--    2) klass
--    3) data
--    4) now
--    5) delay
--    *) [priority, p], [tags, t], [retries, r], [depends, '[...]']
function QlessQueue:put(now, jid, klass, data, delay, ...)
    assert(jid  , 'Put(): Arg "jid" missing')
    assert(klass, 'Put(): Arg "klass" missing')
    data  = assert(cjson.decode(data),
        'Put(): Arg "data" missing or not JSON: ' .. tostring(data))
    delay = assert(tonumber(delay),
        'Put(): Arg "delay" not a number: ' .. tostring(delay))

    -- Read in all the optional parameters
    local options = {}
    for i = 1, #arg, 2 do options[arg[i]] = arg[i + 1] end

    -- Let's see what the old priority, history and tags were
    local history, priority, tags, oldqueue, state, failure, retries, worker = unpack(redis.call('hmget', 'ql:j:' .. jid, 'history', 'priority', 'tags', 'queue', 'state', 'failure', 'retries', 'worker'))

    -- Sanity check on optional args
    retries  = assert(tonumber(options['retries']  or retries or 5) , 'Put(): Arg "retries" not a number: ' .. tostring(options['retries']))
    tags     = assert(cjson.decode(options['tags'] or tags or '[]' ), 'Put(): Arg "tags" not JSON'          .. tostring(options['tags']))
    priority = assert(tonumber(options['priority'] or priority or 0), 'Put(): Arg "priority" not a number'  .. tostring(options['priority']))
    local depends = assert(cjson.decode(options['depends'] or '[]') , 'Put(): Arg "depends" not JSON: '     .. tostring(options['depends']))

    -- Delay and depends are not allowed together
    if delay > 0 and #depends > 0 then
        error('Put(): "delay" and "depends" are not allowed to be used together')
    end

    -- Send out a log message
    redis.call('publish', 'log', cjson.encode({
        jid   = jid,
        event = 'put',
        queue = self.name
    }))

    -- Update the history to include this new change
    local history = cjson.decode(history or '{}')
    table.insert(history, {
        q     = self.name,
        put   = math.floor(now)
    })

    -- If this item was previously in another queue, then we should remove it from there
    if oldqueue then
        redis.call('zrem', 'ql:q:' .. oldqueue .. '-work', jid)
        redis.call('zrem', 'ql:q:' .. oldqueue .. '-locks', jid)
        redis.call('zrem', 'ql:q:' .. oldqueue .. '-scheduled', jid)
        redis.call('zrem', 'ql:q:' .. oldqueue .. '-depends', jid)
    end

    -- If this had previously been given out to a worker,
    -- make sure to remove it from that worker's jobs
    if worker then
        redis.call('zrem', 'ql:w:' .. worker .. ':jobs', jid)
        -- We need to inform whatever worker had that job
        redis.call('publish', worker, cjson.encode({
            jid   = jid,
            event = 'put',
            queue = self.name
        }))
    end

    -- If the job was previously in the 'completed' state, then we should remove
    -- it from being enqueued for destructination
    if state == 'complete' then
        redis.call('zrem', 'ql:completed', jid)
    end

    -- Add this job to the list of jobs tagged with whatever tags were supplied
    for i, tag in ipairs(tags) do
        redis.call('zadd', 'ql:t:' .. tag, now, jid)
        redis.call('zincrby', 'ql:tags', 1, tag)
    end

    -- If we're in the failed state, remove all of our data
    if state == 'failed' then
        failure = cjson.decode(failure)
        -- We need to make this remove it from the failed queues
        redis.call('lrem', 'ql:f:' .. failure.group, 0, jid)
        if redis.call('llen', 'ql:f:' .. failure.group) == 0 then
            redis.call('srem', 'ql:failures', failure.group)
        end
        -- The bin is midnight of the provided day
        -- 24 * 60 * 60 = 86400
        local bin = failure.when - (failure.when % 86400)
        -- We also need to decrement the stats about the queue on
        -- the day that this failure actually happened.
        redis.call('hincrby', 'ql:s:stats:' .. bin .. ':' .. self.name, 'failed'  , -1)
    end

    -- First, let's save its data
    redis.call('hmset', 'ql:j:' .. jid,
        'jid'      , jid,
        'klass'    , klass,
        'data'     , cjson.encode(data),
        'priority' , priority,
        'tags'     , cjson.encode(tags),
        'state'    , ((delay > 0) and 'scheduled') or 'waiting',
        'worker'   , '',
        'expires'  , 0,
        'queue'    , self.name,
        'retries'  , retries,
        'remaining', retries,
        'history'  , cjson.encode(history))

    -- These are the jids we legitimately have to wait on
    for i, j in ipairs(depends) do
        -- Make sure it's something other than 'nil' or complete.
        local state = redis.call('hget', 'ql:j:' .. j, 'state')
        if (state and state ~= 'complete') then
            redis.call('sadd', 'ql:j:' .. j .. '-dependents'  , jid)
            redis.call('sadd', 'ql:j:' .. jid .. '-dependencies', j)
        end
    end

    -- Now, if a delay was provided, and if it's in the future,
    -- then we'll have to schedule it. Otherwise, we're just
    -- going to add it to the work queue.
    if delay > 0 then
        redis.call('zadd', 'ql:q:' .. self.name .. '-scheduled', now + delay, jid)
    else
        if redis.call('scard', 'ql:j:' .. jid .. '-dependencies') > 0 then
            redis.call('zadd', 'ql:q:' .. self.name .. '-depends', now, jid)
            redis.call('hset', 'ql:j:' .. jid, 'state', 'depends')
        else
            redis.call('zadd', 'ql:q:' .. self.name .. '-work', priority - (now / 10000000000), jid)
        end
    end

    -- Lastly, we're going to make sure that this item is in the
    -- set of known queues. We should keep this sorted by the 
    -- order in which we saw each of these queues
    if redis.call('zscore', 'ql:queues', self.name) == false then
        redis.call('zadd', 'ql:queues', now, self.name)
    end

    if redis.call('zscore', 'ql:tracked', jid) ~= false then
        redis.call('publish', 'put', jid)
    end

    return jid
end

-- Unfail(0, now, group, queue, [count])
--
-- Move `count` jobs out of the failed state and into the provided queue
function QlessQueue:unfail(now, group, count)
    assert(group, 'Unfail(): Arg "group" missing')
    count = assert(tonumber(count or 25),
        'Unfail(): Arg "count" not a number: ' .. tostring(count))

    -- Get up to that many jobs, and we'll put them in the appropriate queue
    local jids = redis.call('lrange', 'ql:f:' .. group, -count, -1)

    -- Get each job's original number of retries, 
    local jobs = {}
    for index, jid in ipairs(jids) do
        local packed = redis.call('hgetall', 'ql:j:' .. jid)
        local unpacked = {}
        for i = 1, #packed, 2 do unpacked[packed[i]] = packed[i + 1] end
        table.insert(jobs, unpacked)
    end

    -- And now set each job's state, and put it into the appropriate queue
    local toinsert = {}
    for index, job in ipairs(jobs) do
        job.history = cjson.decode(job.history or '{}')
        table.insert(job.history, {
            q   = self.name,
            put = math.floor(now)
        })
        redis.call('hmset', 'ql:j:' .. job.jid,
            'state'    , 'waiting',
            'worker'   , '',
            'expires'  , 0,
            'queue'    , self.name,
            'remaining', job.retries or 5,
            'history'  , cjson.encode(job.history))
        table.insert(toinsert, job.priority - (now / 10000000000))
        table.insert(toinsert, job.jid)
    end

    redis.call('zadd', 'ql:q:' .. self.name .. '-work', unpack(toinsert))

    -- Remove these jobs from the failed state
    redis.call('ltrim', 'ql:f:' .. group, 0, -count - 1)
    if (redis.call('llen', 'ql:f:' .. group) == 0) then
        redis.call('srem', 'ql:failures', group)
    end

    return #jids
end

function QlessQueue:recur(now, jid, klass, data, spec, ...)
    assert(jid  , 'RecurringJob On(): Arg "jid" missing')
    assert(klass, 'RecurringJob On(): Arg "klass" missing')
    assert(spec , 'RecurringJob On(): Arg "spec" missing')
    data = assert(cjson.decode(data),
        'RecurringJob On(): Arg "data" not JSON: ' .. tostring(data))

    -- At some point in the future, we may have different types of recurring
    -- jobs, but for the time being, we only have 'interval'-type jobs
    if spec == 'interval' then
        local interval = assert(tonumber(arg[1]),
            'Recur(): Arg "interval" not a number: ' .. tostring(arg[1]))
        local offset   = assert(tonumber(arg[2]),
            'Recur(): Arg "offset" not a number: '   .. tostring(arg[2]))
        if interval <= 0 then
            error('Recur(): Arg "interval" must be greater than or equal to 0')
        end

        -- Read in all the optional parameters
        local options = {}
        for i = 3, #arg, 2 do options[arg[i]] = arg[i + 1] end
        options.tags = assert(cjson.decode(options.tags or {}),
            'Recur(): Arg "tags" must be JSON string array: ' .. tostring(
                options.tags))
        options.priority = assert(tonumber(options.priority or 0),
            'Recur(): Arg "priority" not a number: ' .. tostring(
                options.priority))
        options.retries = assert(tonumber(options.retries  or 0),
            'Recur(): Arg "retries" not a number: ' .. tostring(
                options.retries))

        local count, old_queue = unpack(redis.call('hmget', 'ql:r:' .. jid, 'count', 'queue'))
        count = count or 0

        -- If it has previously been in another queue, then we should remove 
        -- some information about it
        if old_queue then
            redis.call('zrem', 'ql:q:' .. old_queue .. '-recur', jid)
        end
        
        -- Do some insertions
        redis.call('hmset', 'ql:r:' .. jid,
            'jid'     , jid,
            'klass'   , klass,
            'data'    , cjson.encode(data),
            'priority', options.priority,
            'tags'    , cjson.encode(options.tags or {}),
            'state'   , 'recur',
            'queue'   , self.name,
            'type'    , 'interval',
            -- How many jobs we've spawned from this
            'count'   , count,
            'interval', interval,
            'retries' , options.retries)
        -- Now, we should schedule the next run of the job
        redis.call('zadd', 'ql:q:' .. self.name .. '-recur', now + offset, jid)
        
        -- Lastly, we're going to make sure that this item is in the
        -- set of known queues. We should keep this sorted by the 
        -- order in which we saw each of these queues
        if redis.call('zscore', 'ql:queues', self.name) == false then
            redis.call('zadd', 'ql:queues', now, self.name)
        end
        
        return jid
    else
        error('Recur(): schedule type "' .. tostring(spec) .. '" unknown')
    end
end

function QlessQueue:length()
    return redis.call('zcard', 'ql:q:' .. self.name .. '-locks') +
        redis.call('zcard', 'ql:q:' .. self.name .. '-work') +
        redis.call('zcard', 'ql:q:' .. self.name .. '-scheduled')
end