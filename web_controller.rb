class WebController < Natural20::Controller
    class ManualControl < StandardError
    end

    def initialize(user, socket)
        @user = user
        @socket = socket
    end

    def update_socket(socket)
        @socket = socket
    end

    def roll_for(entity, die_type, number_of_times, description, advantage: false, disadvantage: false)
    end

    # Return moves by a player using the commandline UI
    # @param entity [Natural20::Entity] The entity to compute moves for
    # @param battle [Natural20::Battle] An instance of the current battle
    # @return [Array(Natural20::Action)]
    def move_for(entity, battle)
        @socket.send({type: 'turn', message: { id: entity.entity_uid} }.to_json)
        raise WebController::ManualControl.new
    end
end