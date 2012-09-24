#! /usr/bin/env coffee

# Module dependencies.

optimist = require 'optimist'
express = require 'express'
path = require 'path'
fs = require 'fs'
hbs = require 'hbs'
redis = require 'redis'
mqtt = require "mqttjs"
EventEmitter = require('events').EventEmitter
RedisStore = require('connect-redis')(express)
Mincer  = require('mincer')

# Create Server

module.exports.app = app = express()
http = require('http').createServer(app)

# Configuration

app.redis = {}

module.exports.configure = configure = ->
  app.configure 'development', ->
    app.use(express.errorHandler({ dumpExceptions: true, showStack: true }))

  app.configure 'production', ->
    app.use(express.errorHandler())

  app.configure -> 
    app.set('views', __dirname + '/app/views')
    app.set('view engine', 'hbs')
    app.use(express.bodyParser())
    app.use(express.methodOverride())
    app.use(express.cookieParser())
    app.use(express.session(secret: "wyRLuS5A79wLn3ItlGVF61Gt", 
      store: new RedisStore(client: app.redis.client), maxAge: 1000 * 60 * 60 * 24 * 14)) # two weeks

    helperContext = {}
    environment = new Mincer.Environment()
    environment.appendPath('app/assets/js')
    environment.appendPath('app/assets/css')
    app.use("/assets", Mincer.createServer(environment))

    app.use(app.router)
    app.use(express.static(__dirname + '/public'))

    # dummy helper that injects extension
    rewrite_extension = (source, ext) ->
      source_ext = path.extname(source)
      if (source_ext == ext) 
        source 
      else
        (source + ext)

    # returns a list of asset paths
    find_asset_paths = (logicalPath, ext) ->
      asset = environment.findAsset(logicalPath)
      paths = []

      if (!asset)
        return null

      if ('production' != process.env.NODE_ENV && asset.isCompiled)
        asset.toArray().forEach (dep) ->
          paths.push('/assets/' + rewrite_extension(dep.logicalPath, ext) + '?body=1')
      else
        paths.push('/assets/' + rewrite_extension(asset.digestPath, ext))

      return paths

    hbs.registerHelper 'js', (logicalPath) ->
      paths = find_asset_paths(logicalPath, ".js")

      if (!paths) 
        # this will help us notify that given logicalPath is not found
        # without "breaking" view renderer
        return new hbs.SafeString('<script type="application/javascript">alert(Javascript file ' +
          JSON.stringify(logicalPath).replace(/"/g, '\\"') +
          ' not found.")</script>')

      result = paths.map (path) ->
        '<script type="application/javascript" src="' + path + '"></script>'
      new hbs.SafeString(result.join("\n"))

    hbs.registerHelper 'css', (logicalPath) ->
      paths = find_asset_paths(logicalPath, ".css")

      if (!paths) 
        # this will help us notify that given logicalPath is not found
        # without "breaking" view renderer
        return new hbs.SafeString('<script type="application/javascript">alert(CSS file ' +
          JSON.stringify(logicalPath).replace(/"/g, '\\"') +
          ' not found.")</script>')

      result = paths.map (path) ->
        '<link rel="stylesheet" type="text/css" href="' + path + '" />'
      new hbs.SafeString(result.join("\n"))

  # setup websockets
  io = app.io = require('socket.io').listen(http)

  io.configure 'production', ->
    io.enable('browser client minification');  # send minified client
    io.enable('browser client etag');          # apply etag caching logic based on version number
    io.enable('browser client gzip');          # gzip the file
    io.set('log level', 0)

  io.configure 'test', ->
    io.set('log level', 0)

  # Helpers
  helpersPath = __dirname + "/app/helpers/"
  for helper in fs.readdirSync(helpersPath)
    app.helpers require(helpersPath + helper) if helper.match /(js|coffee)$/

  load("models")
  load("controllers")

load = (key) ->
  app[key] = {}
  loadPath = __dirname + "/app/#{key}/"
  for component in fs.readdirSync(loadPath)
    if component.match /(js|coffee)$/
      component = path.basename(component, path.extname(component))
      loadedModule = require(loadPath + component)(app)
      component = loadedModule.name if loadedModule.name? and loadedModule.name != ""
      app[key][component] = loadedModule


hbs.registerHelper 'json', (context) -> 
  new hbs.SafeString(JSON.stringify(context))

hbs.registerHelper 'notest', (options) -> 
  if process.env.NODE_ENV != "test"
    input = options.fn(@)
    return input
  else
    return ""

hbs.registerHelper 'markdown', (options) ->
  input = options.fn(@)
  result = require( "markdown" ).markdown.toHTML(input)
  return result

# Start the module if it's needed

optionParser = optimist.
  default('port', 3000).
  default('mqtt', 1883).
  default('redis-port', 6379).
  default('redis-host', '127.0.0.1').
  default('redis-db', 0).
  usage("Usage: $0 [-p WEB-PORT] [-m MQTT-PORT] [-rp REDIS-PORT] [-rh REDIS-HOST]").
  alias('port', 'p').
  alias('mqtt', 'm').
  alias('redis-port', 'rp').
  alias('redis-host', 'rh').
  alias('redis-db', 'rd').
  describe('port', 'The port the web server will listen to').
  describe('mqtt', 'The port the mqtt server will listen to').
  describe('redis-port', 'The port of the redis server').
  describe('redis-host', 'The host of the redis server').
  boolean("help").
  describe("help", "This help")

argv = optionParser.argv

module.exports.setupRedis = setupRedis = (opts = {}) ->
  args = [opts.port, opts.host]
  app.redis.pubsub = redis.createClient(args...)
  app.redis.pubsub.select(opts.db || 0)
  app.redis.client = redis.createClient(args...)
  app.redis.client.select(opts.db || 0)

start = module.exports.start = (opts={}, cb=->) ->

  opts.port ||= argv.port
  opts.mqtt ||= argv.mqtt
  opts.redisPort ||= argv['redis-port']
  opts.redisHost ||= argv['redis-host']
  opts.redisDB ||= argv['redis-db']

  if argv.help
    optionParser.showHelp()
    return 1

  setupRedis(port: opts.redisPort, host: opts.redisHost, db: opts.redisDB)
  configure()

  countDone = 0
  done = ->
    cb() if countDone++ == 2

  http.listen opts.port, ->
    console.log("mqtt-rest web server listening on port %d in %s mode", opts.port, app.settings.env)
    done()

  mqtt.createServer(app.controllers.mqtt_api).listen opts.mqtt, ->
    console.log("mqtt-rest mqtt server listening on port %d in %s mode", opts.mqtt, app.settings.env)
    done()

  app

if require.main.filename == __filename
  start()
