HTTP            = require('http')
HTTPS           = require('https')
EventEmitter    = require('events').EventEmitter
WebSocketClient = require('websocket').client

{Robot, Adapter, TextMessage, EnterMessage, LeaveMessage, Response} = require 'hubot'

try
  {TextMessage} = require '../../../src/message' # because of bugs with new version of nodejs

class Kato extends Adapter
  constructor: (robot) ->
    super robot
    @logger = robot.logger

  send: (envelope, strings...) ->
    @client.send(envelope.room, str) for str in strings

  reply: (envelope, strings...) ->
    strings = strings.map (s) -> "#{envelope.user.name}: #{s}"
    @send envelope.user, strings...

  run: ->
    self = @

    options =
      api_url : process.env.HUBOT_KATO_API || "https://api.kato.im"
      login   : process.env.HUBOT_KATO_LOGIN
      password: process.env.HUBOT_KATO_PASSWORD
      rooms   : process.env.HUBOT_KATO_ROOMS
    options.rooms = options.rooms.split(",") if options.rooms
    @logger.debug "Kato adapter options: #{JSON.stringify options}"

    unless options.login? and options.password? and options.rooms?
      @robot.logger.error \
        "Not enough parameters provided. I need a login, password and rooms"
      process.exit(1)

    client = new KatoClient(options, @robot)

    client.on "TextMessage", (user, message) ->
      unless user.id is client.account_id
        self.receive new TextMessage user, message

    client.on 'reconnect', () ->
      setTimeout ->
        client.Login()
      , 5000

    client.Login()
    @client = client
    self.emit "connected"

exports.use = (robot) ->
  new Kato robot

class KatoClient extends EventEmitter
  self = @
  constructor: (options, @robot) ->
    self = @
    [schema, host] = options.api_url.split("://")
    self.secure = schema == "https"
    self.api_host = host
    self.login = options.login
    self.password = options.password
    self.rooms = options.rooms

    @.on 'login', (err) ->
      @WebSocket()

  Login: () ->
    logger = @robot.logger
    id = @uuid()
    data = JSON.stringify
      email: self.login
      password: self.password

    @put "/sessions/"+id, data, (err, data) ->
      {response, body} = data
      switch response.statusCode
        when 200
          self.sessionKey = response.headers['set-cookie'][0].split(';')[0]
          self.sessionId = id
          json = JSON.parse body
          self.account_id = json.account_id
          self.session_id = json.id
          self.emit 'login'
        when 403
          logger.error "Invalid login/password combination"
          process.exit(2)
        else
          logger.error "Can't login. Status: #{response.statusCode}, Id: #{id}, Headers: #{JSON.stringify(response.headers)}"
          logger.error "Kato error: #{response.statusCode}"
          self.emit 'reconnect'

  WebSocket: () ->
    logger = @robot.logger
    client = new WebSocketClient()

    client.on 'connectFailed', (error) ->
      console.log('Connect Error: ' + error.toString())

    client.on 'connect', (connection) ->
      self.connection = connection
      connection.on 'close', () ->
        console.log('echo-protocol Connection Closed')
        self.emit 'reconnect'
      connection.on 'error', (error) ->
        console.log('error', error)
      connection.on 'message', (message) ->
        if (message.type == 'utf8')
          data = JSON.parse message.utf8Data
          if data.type == "text"
            user =
              id: data.from.id
              name: data.from.name
              room: data.room_id
            user = self.robot.brain.userForId(user.id, user)
            self.emit "TextMessage", user, data.params.text
          else if data.type == "read" || data.type == "typing" || data.type == "silence"
            # ignore
          else
            console.log("Received: '", data, "'")

      for room_id in self.rooms
        logger.info "Joining #{room_id}"
        connection.sendUTF JSON.stringify
          room_id: room_id
          type: "hello"

    headers =
      'Cookie': self.sessionKey
    client.connect((if self.secure then 'wss' else 'ws') + '://'+self.api_host+'/ws', null, null, headers)

  uuid: (size) ->
    part = (d) ->
      if d then part(d - 1) + Math.ceil((0xffffffff * Math.random())).toString(16) else ''
    part(size || 8)

  send: (room_id, str) ->
    @connection.sendUTF JSON.stringify
      room_id: room_id
      type: "text"
      params:
        text: str
        data:
          renderer: "markdown"

  put: (path, body, callback) ->
    @request "PUT", path, body, callback

  request: (method, path, body, callback) ->
    logger = @robot.logger

    if self.secure
      module = HTTPS
      port = 443
    else
      module = HTTP
      port = 80
    headers =
      "Authorization" : @authorization
      "Host"          : self.api_host
      "Content-Type"  : "application/json"

    options =
      "agent"  : false
      "host"   : self.api_host
      "port"   : port
      "path"   : path
      "method" : method
      "headers": headers

    if method is "POST" || method is "PUT"
      if typeof(body) isnt "string"
        body = JSON.stringify body

      body = new Buffer(body)
      options.headers["Content-Length"] = body.length

    request = module.request options, (response) ->
      data = ""

      response.on "data", (chunk) ->
        data += chunk

      response.on "end", ->
        callback null, {response: response, body: data}

      response.on "error", (err) ->
        logger.error "Kato response error: #{err}"
        callback err, { }

    if method is "POST" || method is "PUT"
      request.end(body, 'binary')
    else
      request.end()

    request.on "error", (err) ->
      logger.error "Kato request error: #{err}"
