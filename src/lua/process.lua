--[[
   key 1 -> rdb:schedule:waiting
   key 2 -> rdb:schedule:queued
   key 3 -> rdb:schedule:active
   key 4 -> rdb:schedule:schedules
   key 5 -> rdb:schedule:lock
   key 6 -> rdb:schedule:hello
   arg 1 -> timestampMs
   arg 2 -> lockTime
   arg 3 -> lockId - this is the redibox worker id (this.core.id)
   arg 4 -> lockInterval
]]
local lock = redis.call('get', KEYS[5])

if lock then
  return lock
end

redis.call('set', KEYS[5], ARGV[3], 'PX', tonumber(ARGV[2]))

local time = tonumber(ARGV[1])
-- get occurrences that a ready to run based on timestamp
-- we slightly creep ahead a couple ms to ensure jubs are picked up on the dot
-- or as close to it as possible
local occurrences = redis.call('zrangebyscore', KEYS[1], 0, time)

-- remove processed occurrences from sorted set
if occurrences then
  -- push
  for i, occurrence in ipairs(occurrences) do
    -- get the schedule json string for hash table
    local name, versionHash = occurrence:match("([^,]+)|||([^,]+)")
    local schedule = redis.call('hget', KEYS[4], name)

    -- continue if we found schedule
    if schedule then

      -- try json decode schedule so we can check if it's still enabled
      local scheduleParsed = cjson.decode(schedule)

      local enabled = scheduleParsed.enabled
      local scheduleVersionHash = scheduleParsed.versionHash
      local nextTimestamp = tonumber(scheduleParsed.occurrence.next)
      local endTimestamp = tonumber(scheduleParsed.occurrence.ends)
      local startsTimestamp = tonumber(scheduleParsed.occurrence.starts)
      local runOnce = (scheduleParsed.occurrence.once and not scheduleParsed.occurrence.onceCompleted)

      -- only valid if schedule is enabled still
      -- and it's hash matches the hash at time of creating this occurrence
      if enabled and versionHash == scheduleVersionHash then
        -- check this occurence is not > end timestamp
        if runOnce or (nextTimestamp <= endTimestamp and nextTimestamp >= startsTimestamp) then
          -- update number of times ran counter
          scheduleParsed.timesRan = scheduleParsed.timesRan + 1
          scheduleParsed.lastRan = time

          if runOnce then
            scheduleParsed.occurrence.onceCompleted = true
          end

          -- re-encode json and update hash
          local updatedSchedule = cjson.encode(scheduleParsed);
          redis.call('hset', KEYS[4], name, updatedSchedule)

          -- push to work queue
          redis.call('RPUSH', KEYS[2], updatedSchedule)
        else
          -- do nothing - it's past the end date
          -- just disable the schedule and update it
          scheduleParsed.enabled = false
          scheduleParsed.stoppedAt = time
          redis.call('hset', KEYS[4], name, cjson.encode(scheduleParsed))
        end
      end
    end
    -- all done, now remove this occurences
    redis.call('zrem', KEYS[1], occurrence)
  end
end

-- set lock to expire after half the interval time
if redis.call('get', KEYS[5]) == ARGV[3] then
  redis.debug('EXIRING KEY ' .. KEYS[5] .. ' with token ' .. ARGV[3])
  redis.call('pexpire', KEYS[5], tonumber(ARGV[4]) - 10)
end

-- return a count of schedules pushed to ready
return { #occurrences, redis.call('set', KEYS[6], time, 'NX') }
--return #occurrences
