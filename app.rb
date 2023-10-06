require 'sinatra'
require 'sinatra/streaming'
require 'sinatra/contrib'
require 'bundler'

Bundler.require


$LOAD_PATH << "."

require 'active_support/core_ext/hash'
enable :sessions

require 'mini_magick'
require 'json'
require 'natural_20/web/json_renderer'

require 'logger'
require 'web_logger'

Faye::WebSocket.load_adapter('thin')

logger = Logger.new(STDOUT)
logger.level = Logger::INFO

Natural20::EventManager.standard_cli

set :sockets, []

set :session_secret, "fe9707b4704da2a96d0fd3cbbb465756e124b8c391c72a27ff32a062110de589"

helpers do
  def logged_in?
    !session[:username].nil?
  end

  def user_role
    login_info = settings.logins.find { |login| login["name"].downcase == session[:username] }
    login_info["role"]
  end
end

LEVEL = "example/goblin_ambush"


index_file = File.read(File.join(LEVEL, 'index.json'))
index_hash = JSON.parse(index_file)

TITLE = index_hash["title"]
TILE_PX = index_hash["tile_size"].to_i
HEIGHT = index_hash["height"].to_i
WIDTH = index_hash["width"].to_i
BACKGROUND = index_hash["background"]
LOGIN_BACKGROUND = index_hash["login_background"]
BATTLEMAP = index_hash["map"]
SOUNDTRACKS = index_hash["soundtracks"]
LOGINS = index_hash["logins"]

game_session = Natural20::Session.new_session(LEVEL)
battlemap = Natural20::BattleMap.new(game_session, BATTLEMAP)
renderer = Natural20::Web::JsonRenderer.new(battlemap, nil)
set :map, battlemap
set :battle, nil
set :ai_controller, nil
set :current_soundtrack, nil
set :logins, LOGINS
set :timeout, 600

def create_2d_array(n, m)
  Array.new(n) { Array.new(m) { rand(1..4) } }
end

class WebSocketLogger
  def initialize(settings)
    @settings = settings
  end
  def output(message)
    @settings.sockets.each do |socket|
      socket.send({type: 'console', message: message}.to_json)
    end
  end
end

web_logger = WebLogger.new(WebSocketLogger.new(settings))
web_logger.standard_web

get '/assets/:asset_name' do
  asset_name = params[:asset_name]
  file_path = File.join(LEVEL, "assets", asset_name)
  if File.exist?(file_path)
    file_contents = File.read(file_path)
  else
    halt 404
  end
end

get '/path' do
  content_type :json
  source = params[:from]
  destination = params[:to]
  entity = settings.map.entity_at(source['x'].to_i, source['y'].to_i)

  path = AiController::PathCompute.new(nil, settings.map, entity).compute_path(source['x'].to_i, source['y'].to_i, destination['x'].to_i, destination['y'].to_i)
  cost = settings.map.movement_cost(entity, path)
  placeable = settings.map.placeable?(entity, destination['x'].to_i, destination['y'].to_i, settings.battle, false)
  { path: cost.movement, cost: cost, placeable: placeable }.to_json
end

before do
  redirect to('/login') unless logged_in? || request.path_info == '/login' || request.path_info.start_with?('/assets')
end

get '/login' do
  erb :login, locals: { title: TITLE, background: LOGIN_BACKGROUND }
end


post '/login' do
  username = params[:username]
  password = params[:password]

  # Find the login information for the given username
  login_info = settings.logins.find { |login| login["name"].downcase == username.downcase }

  # If the login information is not found or the password is incorrect, redirect to the login page
  if login_info.nil? || login_info["password"] != password
    content_type :json
    return { error: "Invalid Login Credentials" }.to_json
  end

  # If validation is successful, create a session cookie for the user
  session[:username] = username.downcase

  # Redirect to '/'
  return { status: 'ok' }.to_json
end

get '/' do
    file_path = File.join(LEVEL, "assets", BACKGROUND)
    image = MiniMagick::Image.open(file_path)
    width = image.width
    height = image.height

    @my_2d_array = [renderer.render]
    logger.info @my_2d_array

    tiles_dimenstion_height = HEIGHT * TILE_PX
    tiles_dimenstion_width = WIDTH * TILE_PX

    haml :index, locals: { tiles: @my_2d_array, tile_size_px: TILE_PX,
                           background_path: "assets/#{BACKGROUND}", background_width: tiles_dimenstion_width,
                           background_height: tiles_dimenstion_height,
                           battle: settings.battle,
                           soundtrack: settings.current_soundtrack,
                           title: TITLE,
                           role: user_role}
end

get '/update' do
  @my_2d_array = [renderer.render]
  haml :map, locals: { tiles: @my_2d_array, tile_size_px: TILE_PX, is_setup: (params[:is_setup] == 'true')}
end

get '/event' do
  if Faye::WebSocket.websocket?(request.env)
    ws = Faye::WebSocket.new(request.env)

    ws.on :open do |event|
      logger.info("open #{ws}")
      settings.sockets << ws
      ws.send({type: 'info', message: ''}.to_json)
    end

    ws.on :message do |event|
      data = JSON.parse(event.data)
      case data['type']
      when 'ping'
        ws.send({type: 'ping', message: 'pong'}.to_json)
      when 'message'
       logger.info("message #{data['message']}")
       if (data['message']['action'] == 'move')
        entity = settings.map.entity_at(data['message']['from']['x'], data['message']['from']['y'])

        if (settings.map.placeable?(entity, data['message']['to']['x'], data['message']['to']['y']))
          settings.map.move_to!(entity, data['message']['to']['x'], data['message']['to']['y'], settings.battle)
          settings.sockets.each do |socket|
            socket.send({type: 'move', message: {from: data['message']['from'], to: data['message']['to']}}.to_json)
          end
        end
       end
      else
        ws.send({type: 'error', message: 'Unknown command!'}.to_json)
      end
    end

    ws.on :close do |event|
      logger.info("close #{ws}")
      settings.sockets.delete(ws)
    end

    ws.rack_response
  else
    status 400
    "Websocket connection required"
  end
end

post "/start" do
  settings.battle = Battle.new(game_session, settings.map)
  content_type :json
  { status: 'ok' }.to_json
end

get "/tracks" do
  tracks = SOUNDTRACKS.each_with_index.collect do |track, index|
    OpenStruct.new({id: index, url: track['file'], name: track['name'] })
  end
  haml :soundtrack, locals: { tracks: tracks, track_id: params[:track_id].to_i }
end

post "/sound" do
  content_type :json
  track_id = params[:track_id].to_i

  if track_id == -1
    settings.current_soundtrack = nil
    settings.sockets.each do |socket|
      socket.send({type: 'stoptrack', message: { }}.to_json)
    end
  else
    url = SOUNDTRACKS[track_id]['file']
    
    settings.current_soundtrack = { url: url, id: track_id }

    settings.sockets.each do |socket|
      socket.send({type: 'track', message: { url: url, id: track_id }}.to_json)
    end
  end
  { status: 'ok' }.to_json
end

post "/volume" do
  content_type :json
  volume = params[:volume].to_i
  settings.sockets.each do |socket|
    socket.send({type: 'volume', message: { volume: volume }}.to_json)
  end
  { status: 'ok' }.to_json
end


# sample request: {"battle_turn_order"=>{"0"=>{"id"=>"f437404e-52f9-40d2-b7d4-d6390d397d30", "group"=>"a"}, "1"=>{"id"=>"afe24663-a079-4390-9fbb-c12218b46f7b", "group"=>"a"}}}::1 - - [02/Oct/2023:19:26:41 +0800] "POST /battle HTTP/1.1" 2
post "/battle" do
  content_type :json
  settings.ai_controller =  AiController::Standard.new
  settings.battle = Natural20::Battle.new(game_session, settings.map, settings.ai_controller)

  params[:battle_turn_order].values.each do |param_item|
    entity = settings.map.entity_by_uid(param_item['id'])
    settings.battle.add(entity, param_item['group'].to_sym)
    entity.reset_turn!(settings.battle)
  end
  settings.battle.start
  settings.sockets.each do |socket|
    socket.send({type: 'initiative', message: { }}.to_json)
    socket.send({type: 'move', message: { }}.to_json)
  end


  { status: 'ok' }.to_json
end

get "/turn_order" do
  haml :battle, locals: { battle: settings.battle }
end

def ai_loop
  entity = settings.battle.current_turn
  cycles = 0
  loop do
    cycles += 1
    action = settings.battle.move_for(entity)

    if action.nil?
      puts "#{entity.name}: End turn."
      break
    end

    settings.battle.action!(action)
    settings.battle.commit(action)

    break if action.nil? || entity.unconscious?
  end
end

def end_current_battle
  settings.battle = nil
  settings.ai_controller = nil

  settings.sockets.each do |socket|
    socket.send({type: 'stop', message: { }}.to_json)
  end
end

post "/next_turn" do
  if settings.battle

    settings.battle.start_turn

    current_turn = settings.battle.current_turn
    
    while current_turn.dead?
      current_turn.send(:resolve_trigger, :end_of_turn)
      
      settings.battle.end_turn
      settings.battle.next_turn
      current_turn = settings.battle.current_turn

      if settings.battle.battle_ends?
        end_current_battle
        return { status: 'tpk' }.to_json
      end
    end

    current_turn.reset_turn!(settings.battle)
    ai_loop
    current_turn.send(:resolve_trigger, :end_of_turn)

    settings.battle.end_turn
    result = settings.battle.next_turn
    
    if settings.battle.battle_ends?
      end_current_battle
      return { status: 'tpk' }.to_json
    end
    
    settings.sockets.each do |socket|
      socket.send({type: 'initiative', message: { index: settings.battle.current_turn_index }}.to_json)
      socket.send({type: 'move', message: { id: current_turn.entity_uid }}.to_json)
    end
  end
end

post "/stop" do
  if settings.battle
    settings.battle = nil
    settings.ai_controller = nil

    settings.sockets.each do |socket|
      socket.send({type: 'stop', message: { }}.to_json)
    end
  end
end

post "/logout" do
  session[:username] = nil
  redirect to('/login')
end