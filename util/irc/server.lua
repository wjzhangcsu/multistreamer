local irc = require'util.irc'
local config = require('lapis.config').get()
local date = require'date'
local redis = require'resty.redis'
local slugify = require('lapis.util').slugify
local to_json = require('lapis.util').to_json
local from_json = require('lapis.util').from_json
local User = require'models.user'
local Stream = require'models.stream'
local Account = require'models.account'
local insert = table.insert
local remove = table.remove
local char = string.char
local find = string.find
local len = string.len
local sub = string.sub
local unpack = unpack
if not unpack then
  unpack = table.unpack
end

function string:split(inSplitPattern)
  local res = {}
  local start = 1
  local splitStart, splitEnd = self:find(inSplitPattern,start)
  while splitStart do
    insert(res, sub(self,start,splitStart-1))
    start = splitEnd + 1
    splitStart, splitEnd = self:find(inSplitPattern, start)
  end
  insert(res, self:sub(start) )
  return res
end


if not config.redis_prefix or string.len(config.redis_prefix) == 0 then
  config.redis_prefix = 'multistreamer/'
end

local function redis_publish(endpoint,message)
  local red = redis.new()
  local ok, err = red:connect(config.redis_host)
  if not ok then
    ngx.log(ngx.ERR,'[IRC] Unable to connect to redis: ' .. err)
    return false, err
  end
  local ok, err = red:publish(config.redis_prefix .. endpoint, to_json(message))
  if not ok then return false, err end
  return true, nil
end

local function redis_subscribe(endpoint,red)
  local red = red
  if not red then
    red = redis.new()
    local ok, err = red:connect(config.redis_host)
    if not ok then
      ngx.log(ngx.ERR,'[IRC] Unable to connect to redis: ' .. err)
      return false, err
    end
  end
  local ok, err = red:subscribe(config.redis_prefix .. endpoint)
  if not ok then return false, err end
  return true, red
end


local IRCServer = {}
IRCServer.__index = IRCServer

function IRCServer.new(socket,user,parentServer)
  local server = {}
  server.ready = false
  if parentServer then
    curState = parentServer:getState()
    server.socket = socket
    server.user = user
    server.rooms = curState.rooms
    server.users = curState.users
    server.users[user.nick] = {}
    server.users[user.nick].user = user
    server.users[user.nick].socket = socket

    redis_publish('irc:events', {
      event = 'login',
      nick = user.nick,
      username = user.username,
      realname = user.realname,
      id = user.id,
    })
  else
    server.rooms = {}
    server.users = {
      root = {
        user = {
            nick = 'root',
            username = 'root',
            realname = 'root',
            id = 0,
        }
      }
    }
  end

  server.clientFunctions = {
    ['LIST'] = IRCServer.clientList,
    ['JOIN'] = IRCServer.clientJoinRoom,
    ['PING'] = IRCServer.clientPing,
    ['PRIVMSG'] = IRCServer.clientMessage,
    ['QUIT'] = IRCServer.clientQuit,
  }
  setmetatable(server,IRCServer)
  return server
end

function IRCServer:run()
  local running = true

  local ok, red = redis_subscribe('irc:events')
  if not ok then
    ngx.exit(ngx.ERROR)
  end
  redis_subscribe('streams',red)
  redis_subscribe('comments',red)

  self.ready = true

  local red_func = ngx.thread.spawn(function()
    while true do
      local res, err = red:read_reply()
      if err and err ~= 'timeout' then
        ngx.log(ngx.ERR,'[IRC] Redis disconnected!')
         self.ready = false
        return false
      end
      if res then
          local update = from_json(res[3])
          if(res[2] == config.redis_prefix .. 'irc:events') then
            self:processIrcUpdate(update)
          elseif(res[2] == config.redis_prefix .. 'streams') then
            self:processStreamUpdate(update)
          elseif(res[2] == config.redis_prefix .. 'comments') then
            self:processCommentUpdate(update)
          end
      end
    end
  end)
  if self.socket then
    local irc_func = ngx.thread.spawn(function()
      while true do
        local data, err, partial = self.socket:receive('*l')
        local msg
        if data then
          msg = irc.parse_line(data)
        elseif partial then
          msg = irc.parse_line(partial)
        end
        if err == 'closed' then
          return
        end
        if not err or err ~= 'timeout' then
          local ok, err = self:processClientMessage(self.user.nick,msg)
          if not ok then
            ngx.log(ngx.ERR,'[IRC] ' .. err)
            return
          end
        elseif err then
          ngx.log(ngx.ERR,'[IRC] ' .. err)
          return
        end
      end
    end)
    local ok, irc_res, red_res = ngx.thread.wait(irc_func,red_func)
    if coroutine.status(red_func) == 'dead' then
      ngx.thread.kill(irc_func)
    else
      ngx.thread.kill(red_func)
    end
    self:endClient(self.user)
  else
    for _,u in ipairs(User:select()) do
      for _,s in ipairs(u:get_streams()) do
        local room = slugify(u.username)..'-'..slugify(s.name)
        self.rooms[room] = {
          user_id = u.id,
          stream_id = s.id,
          users = {
            root = true,
          },
          topic = s:get('title'),
          mtime = date.diff(s.updated_at,date.epoch()):spanseconds(),
          ctime = date.diff(s.created_at,date.epoch()):spanseconds(),
        }
      end
    end
    local ok, res = ngx.thread.wait(red_func)
    if res == false then
      ngx.exit(ngx.ERROR)
    end
    ngx.exit(ngx.OK)
  end
end

function IRCServer:getState()
  return {
    users = from_json(to_json(self.users)),
    rooms = from_json(to_json(self.rooms)),
  }
end

function IRCServer:processStreamUpdate(update)
  local stream = Stream:find({ id = update.id })
  local sas = stream:get_streams_accounts()
  local user = stream:get_user()
  for _,sa in pairs(sas) do
    local account = sa:get_account()
    account.network = networks[account.network]
    local accountUsername = slugify(account.network.name)..'-'..slugify(account.name)
    local roomName = slugify(user.username) .. '-' ..slugify(stream.name)
    if update.status == 'live' then
      if not self.users[accountUsername] then
        self.users[accountUsername] = {
          user = {
            nick = accountUsername,
            username = accountUsername,
            realname = accountUsername
          }
        }
      end
      self.rooms[roomName].users[accountUsername] = true
      for u,user in pairs(self.rooms[roomName].users) do
        if self.users[u].socket then
          self:sendRoomJoin(u,accountUsername,roomName)
        end
      end
    elseif update.status == 'stopped' then
      for u,user in pairs(self.rooms[roomName].users) do
        if self.users[u].socket then
          self:sendRoomPart(u,accountUsername,roomName)
        end
      end
      self.rooms[roomName].users[accountUsername] = nil
    end
  end
end

function IRCServer:processCommentUpdate(update)
  local account = Account:find({ id = update.account_id })
  local user = account:get_user()
  account.network = networks[account.network]
  local stream = Stream:find({ id = update.stream_id })
  local username = slugify(account.network.name) .. '-' .. slugify(account.name)
  local roomname = slugify(user.username) .. '-' .. stream.slug

  for u,user in pairs(self.rooms[roomname].users) do
    if self.users[u].socket then
      if update.type == 'text' then
        self:sendPrivMessage(u,username,'#'..roomname,'(' .. update.from ..') '..update.text)
      end
    end
  end
end

function IRCServer:processIrcUpdate(update)
  if update.event == 'join' then
    self.rooms[update.room].users[update.nick] = true
    for to,_ in pairs(self.rooms[update.room].users) do
      if self.users[to].socket then
        self:sendRoomJoin(to,update.nick,update.room)
      end
    end
  elseif update.event == 'login' then
    if not self.users[update.nick] then
      self.users[update.nick] = {
          user = {
              nick = update.nick,
              username = update.username,
              realname = update.realname,
              id = update.id,
          }
      }
    end
  elseif update.event == 'logout' then
    for r,room in pairs(self.rooms) do
      if room.users[update.nick] then
        for u,user in pairs(room.users) do
          if self.users[u].socket then
            self:sendRoomPart(u,update.nick,r)
          end
        end
        room.users[update.nick] = nil
      end
    end
    self.users[update.nick] = nil
  elseif update.event == 'message' then
    if update.target:sub(1,1) == '#' then
      local room = update.target:sub(2)
      if self.rooms[room] then
        for u,user in pairs(self.rooms[room].users) do
          if u ~= update.nick and self.users[u].socket then
            self:sendPrivMessage(u,update.nick,'#'..room,update.message)
          end
        end
      end
    else
      if self.users[update.target] and self.users[update.target].socket then
        self:sendPrivMessage(update.target,update.nick,update.nick,update.message)
      end
    end
  end
end

function IRCServer:userList(room)
  local count = 0
  local ulist = ''
  for u,_ in pairs(self.rooms[room].users) do
    count = count + 1
    ulist = ulist .. ' @'..u
  end
  return count, ulist
end

function IRCServer:listRooms(nick,rooms)
  local ok, err = self:sendClientFromServer(nick,'321','Channel','Users','Name')
  if not ok then return false,err end
  for k,v in pairs(rooms) do
    local count, list = self:userList(k)
    local ok, err = self:sendClientFromServer(
      nick,
      '322',
      '#'..k,
      count,
      v.topic)
    if not ok then return false,err end
  end
  ok, err = self:sendClientFromServer(
    nick,
    '323',
    'End of /LIST')
  if not ok then return false,err end
  return true, nil
end

function IRCServer:clientJoinRoom(nick,msg)
  local room = msg.args[1]
  if not room then return self:sendClientFromServer(nick,'403','Channel does not exist') end
  if room:sub(1,1) == '#' then
    room = room:sub(2)
  end
  if not self.rooms[room] then
    return self:sendClientFromServer(nick,'403','Channel does not exist')
  end
  local ok, err = redis_publish('irc:events', {
    event = 'join',
    nick = nick,
    room = room
  })
  if not ok then return false, err end

  return true,nil
end

function IRCServer:clientMessage(nick,msg)
  local target = msg.args[1]
  if target:sub(1,1) == '#' then
    target = target:sub(2)
    if not self.rooms[target] then
      return self:sendClientFromServer(nick,'403','Channel does not exist')
    end
  else
    if not self.users[target] then
      return self:sendClientFromServer(nick,'401','No such nick')
    end
  end
  return redis_publish('irc:events',{
    event = 'message',
    nick = nick,
    target = msg.args[1],
    message = msg.args[2],
  })
end

function IRCServer:clientPing(nick,msg)
  return self:sendFromServer(nick,'PONG',msg.args[1])
end

function IRCServer:sendRoomPart(to,from,room)
  local ok, err = self:sendFromClient(to,from,'PART','#'..room)
  if not ok then return false, err end
  return true,nil
end

function IRCServer:sendPrivMessage(to,msgFrom,msgTarget,message)
  return self:sendFromClient(to,msgFrom,'PRIVMSG',msgTarget,message)
end


function IRCServer:sendRoomJoin(to,from,room)
  local ok, err = self:sendFromClient(to,from,'JOIN','#'..room)
  if not ok then return false, err end

  if to ~= from then return true,nil end

  local code, topic
  if self.rooms[room].topic then
    code = '332'
    topic = self.rooms[room].topic
  else
    code = '331'
    topic = 'Topic not set'
  end

  ok, err = self:sendClientFromServer(from,code,'#'..room,topic)
  if not ok then return false,err end

  ok, err = self:sendNames(from,room)
  if not ok then return false, err end

  return true
end

function IRCServer:sendNames(nick,room)
  local count, userlist = self:userList(room)
  local ok, err = self:sendClientFromServer(
    nick,
    '353',
    '@',
    '#'..room,
    userlist)
  if not ok then return false, err end
  return self:sendClientFromServer(
    nick,
    '366',
    '#' .. room,
    'End of /NAMES list')
end

function IRCServer:clientList(nick,msg)
  if msg.args[1] then
    local room = msg.args[1]
    if room:sub(1,1) == '#' then
      room = room:sub(2)
    end
    return self:listRooms(nick,{ [room] = self.rooms[room] })
  end
  return self:listRooms(nick,self.rooms)
end


function IRCServer:checkNick(nick)
  if self.users[nick] then
    return true
  end
  return false
end

function IRCServer:clientQuit(nick,msg)
  self:endClient({ nick = nick })
  return true,nil
end

function IRCServer:endClient(user)
  self.users[user.nick] = nil
  redis_publish('irc:events',{
    event = 'logout',
    nick = user.nick,
  })
end

function IRCServer:processClientMessage(nick,msg)
  if not msg or not msg.command then
    return false, 'command not given'
  end
  local func = self.clientFunctions[msg.command]
  if not func then
    return self:sendClientFromServer(nick,'482','Not implemented')
  end
  return func(self,nick,msg)
end

function IRCServer:sendFromClient(to,from,...)
  local msg = irc.format_line(':'..
    from .. '!' ..
    self.users[from].user.username .. '@' ..
    config.irc_hostname,...)
  local bytes, err = self.users[to].socket:send(msg .. '\r\n')
  if not bytes then
    return false, err
  end
  return true, nil
end

function IRCServer:sendClientFromServer(nick,...)
  local args = {...}
  insert(args,2,nick)
  return self:sendFromServer(nick,unpack(args))
end

function IRCServer:sendFromServer(nick,...)
  local msg = irc.format_line(':' .. config.irc_hostname,...)
  if self.users[nick].socket then
    local bytes, err = self.users[nick].socket:send(msg .. '\r\n')
    if not bytes then
      return false, err
    end
    return true, nil
  end
  return false, 'socket not available'
end

function IRCServer:isReady()
  return self.ready
end

function IRCServer.startClient(sock,server)
  local logging_in = true
  local user
  local nickname
  local username
  local realname
  local password
  local pass_incoming = false
  local ready_to_attempt = true
  local send_buffer = {}
  local function drain_buffer()
    while(#send_buffer > 0) do
      local v = remove(send_buffer, 1)
      if nickname then
        v = v:gsub('{nick}',nickname)
      end
      if username then
        v = v:gsub('{user}',username)
      end
      if user then
        v = v:gsub('{account}',user.username)
      end
      v = v:gsub('{hostname}',config.irc_hostname)
      sock:send(v .. '\r\n')
    end
  end
  while logging_in do
    local data, err, partial = sock:receive('*l')
    local msg
    if data then
      msg = irc.parse_line(data)
    elseif partial then
      msg = irc.parse_line(partial)
    end
    if err then
      ngx.exit(ngx.ERROR)
    end

    if msg.command == 'NICK' then
      if not msg.args[1] then
        logging_in = false
        break
      end

      local res, err = server:checkNick(msg.args[1])

      if res == true then
        sock:send(':' .. config.irc_hostname .. ' 443 * '..msg.args[1]..' :Nick already in use\r\n')
        logging_in = false
        break
      end
      nickname = msg.args[1]
    end

    if msg.command == 'USER' then
      if not msg.args[1] then
        logging_in = false
        break
      end
      username = msg.args[1]
      realname = msg.args[4]
    end

    if msg.command == 'CAP' then
      if msg.args[1] == 'LS' then
        insert(send_buffer,':{hostname} CAP * LS :multi-prefix sasl')
        ready_to_attempt = false
      elseif msg.args[1] == 'REQ' then
        insert(send_buffer,':{hostname} CAP {nick} ACK :'..msg.args[2])
        ready_to_attempt = false
      elseif msg.args[1] == 'END' then
        ready_to_attempt = true
      end
    end
    if msg.command == 'AUTHENTICATE' then
      if pass_incoming then
        local creds = ngx.decode_base64(msg.args[1]):split(char(0))
        user = User:login(creds[2],creds[3])
        if user then
          if user.username ~= nickname or user.username ~= username then
            insert(send_buffer,':{hostname} 902 {nick} :You must use a nick assigned to you')
            user = nil
          else
            insert(send_buffer,':{hostname} 900 {nick} {nick}!{user}@{hostname} {account} :You are now logged in as {user}')
            insert(send_buffer,':{hostname} 903 {nick} :SASL authenticate successful')
          end
        else
          insert(send_buffer,':{hostname} 904 {nick} :SASL authentication failed')
        end
      else
        if msg.args[1] == '*' then
          insert(send_buffer,':{hostname} 906 {nick} :SASL aborted')
        elseif msg.args[1] ~= 'PLAIN' then
          insert(send_buffer,':{hostname} 908 {nick} PLAIN :Available SASL methods')
        else
          insert(send_buffer,':{hostname} AUTHENTICATE +')
          pass_incoming = true
        end
      end
    end
    if nickname and username then
      drain_buffer()
      if ready_to_attempt then
        logging_in = false
      end
    end

    if err == 'closed' then
      logging_in = false
    end
  end
  if user then
    insert(send_buffer,':{hostname} 001 {nick} :Welcome {nick}!{user}@{hostname}')
    insert(send_buffer,':{hostname} 002 {nick} :Your host is {hostname} running version 0')
    insert(send_buffer,':{hostname} 003 {nick} :This server was created sometime')
    insert(send_buffer,':{hostname} 004 {nick} {hostname} 0 s@ on')
    drain_buffer()
    local u = {
      id = user.id,
      nick = nickname,
      username = username,
      realname = realname,
    }
    return true, u
  end
  return false, 'login failed'
end

return IRCServer