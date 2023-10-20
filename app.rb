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
require 'web_controller'

Faye::WebSocket.load_adapter('thin')

logger = Logger.new(STDOUT)
logger.level = Logger::INFO

Natural20::EventManager.standard_cli

set :sockets, []
set :controllers, {}

set :session_secret, "fe9707b4704da2a96d0fd3cbbb465756e124b8c391c72a27ff32a062110de589"



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
CONTROLLERS = index_hash["default_controllers"]

helpers do
  def logged_in?
    !session[:username].nil?
  end

  def user_role
    login_info = settings.logins.find { |login| login["name"].downcase == session[:username] }
    login_info["role"]
  end

  def commit_and_update(action)
    if settings.battle
      settings.battle.action!(action)
      settings.battle.commit(action)
    else
      action.resolve(session, settings.map, battle: nil)
    end
    settings.sockets.each do |socket|
      socket.send({type: 'move', message: { }}.to_json)
    end
    # game_session.save_game(settings.battle, settings.map)
  end

  def describe_terrain(tile)
    description = []
    description += "Difficult Terrain" if tile[:difficult]
    description += settings.map.thing_at(tile[:x], tile[:y]).map(&:label)
    description.map do |d| "<p>#{d}</p>" end.join.html_safe
  end

  def controller_of?(entity_uid, username)
    if settings.battle
      entity = settings.map.entity_by_uid(entity_uid)
      controller = settings.battle.controller_for(entity)
      return controller.try(:user) == username
    end

    false
  end

  def entity_owners(entity_uid)
    ctrl_info = CONTROLLERS.each.find { |controller| controller['entity_uid'] == entity_uid }
    return [] unless ctrl_info

    ctrl_info['controllers']
  end

  def action_flavors(action)
    if action.try(:second_hand)
      "_second"
    elsif action.try(:unarmed?)
       "_melee"
    elsif action.try(:thrown)
       "_thrown"
    elsif action.try(:ranged_attack?)
       "_ranged"
    else
      ""
    end
  end
end

game_session = Natural20::Session.new_session(LEVEL)

# if game_session.has_save_game?
#   state = game_session.load_save
#   if (state[:battle])
#     set :battle, state[:battle]
#     set :map, state[:map]
#   end
# else
  battlemap = Natural20::BattleMap.new(game_session, BATTLEMAP)
  set :map, battlemap
  set :battle, nil
# end

set :ai_controller, nil
set :current_soundtrack, nil
set :logins, LOGINS
set :timeout, 600
set :waiting_for_user, false

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

    renderer = Natural20::Web::JsonRenderer.new(settings.map, settings.battle)
    @my_2d_array = [renderer.render]

    # logger.info @my_2d_array

    tiles_dimenstion_height = HEIGHT * TILE_PX
    tiles_dimenstion_width = WIDTH * TILE_PX

    haml :index, locals: { tiles: @my_2d_array, tile_size_px: TILE_PX,
                           background_path: "assets/#{BACKGROUND}", background_width: tiles_dimenstion_width,
                           background_height: tiles_dimenstion_height,
                           battle: settings.battle,
                           soundtrack: settings.current_soundtrack,
                           title: TITLE,
                           username: session[:username],
                           role: user_role
                          }
end

get '/update' do
  renderer = Natural20::Web::JsonRenderer.new(settings.map, settings.battle)
  @my_2d_array = [renderer.render]
  haml :map, locals: { tiles: @my_2d_array, tile_size_px: TILE_PX, is_setup: (params[:is_setup] == 'true')}
end

get '/event' do
  if Faye::WebSocket.websocket?(request.env)
    username = request.env['rack.request.query_hash']['username']
    puts  request.env['rack.request.query_hash']
    # cookie passed via const ws = new WebSocket(`ws://${window.location.host}/event`, [`_session_id=${sessionCookie}`]);
    ws = Faye::WebSocket.new(request.env)

    ws.on :open do |event|
      logger.info("open #{ws} for #{username}")
      web_controller_for_user = WebController.new(username, ws)
      settings.controllers[username] ||= web_controller_for_user
      settings.controllers[username].update_socket(ws)

      settings.sockets << ws

      # update existing controllers
      if settings.battle
        settings.battle.update_controllers do |entity, controller|
          if controller.is_a?(WebController) && controller.user == username
            web_controller_for_user
          else
            controller
          end
        end
      end
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
  if params[:battle_turn_order].values.empty?
    status 400
    return { error: 'No entities in turn order' }.to_json
  end
  
  ai_controller =  AiController::Standard.new

  settings.battle = Natural20::Battle.new(game_session, settings.map, ai_controller)

  params[:battle_turn_order].values.each do |param_item|
    entity = settings.map.entity_by_uid(param_item['id'])

    controller = if param_item['controller'] == 'ai'
                   ai_controller
                 else
                  usernames = entity_owners(entity.entity_uid)
                  if usernames.blank?
                    settings.controllers["dm"]
                  else
                    settings.controllers[usernames.first] || settings.controllers["dm"]
                  end
                 end

    settings.battle.add(entity, param_item['group'].to_sym, controller: controller)
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

post "/end_turn" do
  content_type :json
  settings.battle.end_turn
  settings.battle.next_turn
  current_turn = settings.battle.current_turn
  settings.waiting_for_user = false

  settings.sockets.each do |socket|
    socket.send({type: 'initiative', message: { index: settings.battle.current_turn_index }}.to_json)
    socket.send({type: 'move', message: { id: current_turn.entity_uid }}.to_json)
  end

  { status: 'ok' }.to_json
end

post "/next_turn" do
  if settings.battle
    current_turn = settings.battle.current_turn
    if settings.waiting_for_user
      settings.waiting_for_user = false
      current_turn.send(:resolve_trigger, :end_of_turn)

      settings.battle.end_turn
      result = settings.battle.next_turn
      if settings.battle.battle_ends?
        end_current_battle
      end
    end
    
    settings.battle.start_turn

    current_turn = settings.battle.current_turn
    
    while (current_turn.dead? || current_turn.unconscious?)
      current_turn.send(:resolve_trigger, :end_of_turn)
      
      settings.battle.end_turn
      settings.battle.next_turn
      
      current_turn = settings.battle.current_turn


      if settings.battle.battle_ends?
        end_current_battle
      end
    end

    begin
      current_turn.reset_turn!(settings.battle)
      ai_loop
      current_turn.send(:resolve_trigger, :end_of_turn)

      settings.battle.end_turn
      result = settings.battle.next_turn
      

      if settings.battle.battle_ends?
        end_current_battle
      end
    rescue WebController::ManualControl => e
      logger.info("waiting for user to end turn.")
      settings.waiting_for_user = true
    end

    settings.sockets.each do |socket|
      socket.send({type: 'initiative', message: { index: settings.battle.current_turn_index }}.to_json)
      socket.send({type: 'move', message: { id: current_turn.entity_uid }}.to_json)
    end
    game_session.save_game(settings.battle, settings.map)
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

get "/actions" do
  id = params[:id]
  entity = settings.map.entity_by_uid(id)
  if (user_role.include?('dm') || controller_of?(id, session[:username]))
    haml :actions, locals: { entity: entity, battle: settings.battle, session: settings.map.session }
  else
    halt 403
  end
end

post '/action' do
  content_type :json
  action = params[:action]
  entity = settings.map.entity_by_uid(params[:id])
  action_info = {}
  build_map = if action == 'MoveAction'
                if params[:path]
                  move_path = params[:path].map do |index, coord|
                                [index.to_i, [coord[0].to_i, coord[1].to_i]]
                              end.sort_by { |item| item[0] }.map(&:last)
                  action = MoveAction.new(game_session, entity, :move)
                  action.move_path = move_path
                  if settings.battle
                    commit_and_update(action)
                  else
                    if (settings.map.placeable?(entity, move_path.last[0],move_path.last[1]))
                      settings.map.move_to!(entity, *move_path.last, settings.battle)
                      settings.sockets.each do |socket|
                        socket.send({type: 'move', message: {from: move_path.first, to: move_path.last}}.to_json)
                      end
                    end
                  end
                  return { status: 'ok' }.to_json
                else
                  MoveAction.build(game_session, entity)
                end
              elsif action == 'AttackAction'

                action = AttackAction.new(game_session, entity, :attack)
                action.using = params.dig(:opts, :using)

                valid_targets = (settings.battle || settings.map).valid_targets_for(entity, action).map do |target|
                  [target.entity_uid, settings.map.entity_or_object_pos(entity)]
                end.to_h

                weapon_details = game_session.load_weapon(params.dig(:opts,:using))
                if params[:target]
                  target = settings.map.entity_at(params[:target][:x].to_i, params[:target][:y].to_i)
                  if valid_targets.key?(target&.entity_uid)
                    action.target = target
                    commit_and_update(action)
                    return { status: 'ok' }.to_json
                  end
                else
                  action_info[:valid_targets] = valid_targets
                  action_info[:total_targets] = 1
                  action_info[:range] = weapon_details[:range]
                  action_info[:range_max] = weapon_details[:range_max] || weapon_details[:range]
                  action.build_map
                end
              elsif ["GrappleAction", "HelpAction"].include?(action)
                action_instance = Object.const_get(action).new(game_session, entity, Natural20::Action.to_type(action))

                valid_targets = (settings.battle || settings.map).valid_targets_for(entity, action_instance).map do |target|
                  [target.entity_uid, settings.map.entity_or_object_pos(entity)]
                end.to_h
                build_map = Object.const_get(action).build(game_session, entity)

                if params[:target]
                  target = settings.map.entity_at(params[:target][:x].to_i, params[:target][:y].to_i)
                  if valid_targets.key?(target&.entity_uid)
                    action_instance.target = target
                    commit_and_update(action_instance)
                    return { status: 'ok' }.to_json
                  end
                else
                  target_info = build_map.param.first
                  action_info[:valid_targets] = valid_targets
                  action_info[:total_targets] = target_info[:num]
                  action_info[:range] = target_info[:range]
                  action_info[:range_max] = target_info[:range]
                  action_instance.build_map
                end
              else
                build_map = Object.const_get(action).build(game_session, entity)
                if build_map.param.nil?
                  action = build_map.next.call()
                  commit_and_update(action)
                  return { status: 'ok' }.to_json
                end
              end
  action_info.merge(build_map.to_h).to_json
end

get "/add" do
  entity_uid = params[:id]
  entity = settings.map.entity_by_uid(entity_uid)
  
  if settings.battle
    default_group = if entity.is_a?(Natural20::PlayerCharacter)
                      :a
                    else
                      :b
                    end

    settings.battle.add(entity, default_group)
    settings.sockets.each do |socket|
      socket.send({type: 'initiative', message: { index: settings.battle.current_turn_index }}.to_json)
    end

    return ""
  else
    haml :add, locals: { entity: entity }
  end
end

get "/turn" do
  haml :turn, locals: { battle: settings.battle }
end

post "/focus" do
  content_type :json
  x = params[:x]
  y = params[:y]

  settings.sockets.each do |socket|
    socket.send({type: 'focus', message: { x: x, y: y }}.to_json)
  end
  
  { status: 'ok' }.to_json
end

post "/logout" do
  session[:username] = nil
  redirect to('/login')
end