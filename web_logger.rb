class WebLogger
  def initialize(logger)
    @logger = logger
  end

  def standard_web
    Natural20::EventManager.clear
    event_handlers = { died: lambda { |event|
      output "#{show_name(event)} died."
    },
                      unconscious: lambda { |event|
      output "#{show_name(event)} unconscious."
    },
                      attacked: lambda { |event|
      advantage_mod = event[:advantage_mod]
      advantage, disadvantage = event[:adv_info]
      sneak = event[:sneak_attack] ? (event[:sneak_attack]).to_s : nil
      damage = (event[:damage_roll]).to_s
      damage_str = "#{[damage,
                       sneak].compact.join(" + sneak ")} = #{event[:value]} #{event[:damage_type]}"
      if event[:resistant]
        damage_str += " (resistant) #{event[:total_damage]}".colorize(:green)
      end
      if event[:vulnerable]
        damage_str += " (vulnerable) #{event[:total_damage]}".colorize(:green)
      end

      if event[:cover_ac].try(:positive?)
        cover_str = " (behind cover +#{event[:cover_ac]} ac)"
      end
      Time.at(82_800).utc.strftime("%I:%M%p")
      advantage_str = if advantage_mod&.positive?
          " with advantage".colorize(:green)
        elsif advantage_mod&.negative?
          " with disadvantage".colorize(:red)
        else
          ""
        end
      str_token = event[:attack_roll] ? "event.attack" : "event.attack_no_roll"
      output t(str_token, opportunity: event[:as_reaction] ? "Opportunity Attack: " : "",
                          source: show_name(event),
                          target: "#{event[:target].name}#{cover_str}",
                          throws: event[:attack_thrown] ? "throws " : "",
                          attack_name: event[:attack_name],
                          advantage: advantage_str,
                          attack_roll: event[:attack_roll].to_s.colorize(:green),
                          attack_value: event[:attack_roll]&.result,
                          damage: damage_str)
    },
                      damage: lambda { |event|
      output "#{show_name(event)} #{event[:source].describe_health}"
    },
                      miss: lambda { |event|
      advantage_mod = event[:advantage_mod]
      advantage_str = if advantage_mod&.positive?
          " with advantage".colorize(:green)
        elsif advantage_mod&.negative?
          " with disadvantage".colorize(:red)
        else
          ""
        end
      output "#{event[:as_reaction] ? "Opportunity Attack: " : ""} rolled #{advantage_str} #{event[:attack_roll]} ... #{event[:source].name&.colorize(:blue)} missed #{event[:source].pronoun(true)} attack #{event[:attack_name].colorize(:red)} on #{event[:target].name.colorize(:green)}"
    },
                      initiative: lambda { |event|
      output "#{show_name(event)} rolled a #{event[:roll]} = (#{event[:value]}) with dex tie break for initiative."
    },
                      move: lambda { |event|
      output "#{show_name(event)} moved #{(event[:path].size - 1) * event[:feet_per_grid]}ft."
    },
                      dodge: lambda { |event|
      output t("event.dodge", name: show_name(event))
    },
                      hide: lambda { |event|
      output t("event.hide", name: show_name(event), roll: event[:roll].to_s,
                             roll_value: event[:roll].result)
    },
                      help: lambda { |event|
      output "#{show_name(event)} is helping to attack #{event[:target].name&.colorize(:red)}"
    },
                      second_wind: lambda { |event|
      output SecondWindAction.describe(event)
    },
                      heal: lambda { |event|
      output "#{show_name(event)} heals for #{event[:value]}hp"
    },
                      hit_die: lambda { |event|
      output t("event.hit_die", source: show_name(event), roll: event[:roll].to_s,
                                value: event[:roll].result)
    },
                      object_interaction: lambda { |event|
      if event[:roll]
        output "#{event[:roll]} = #{event[:roll].result} -> #{event[:reason]}"
      else
        output (event[:reason]).to_s
      end
    },
                      perception: lambda { |event|
      output "#{show_name(event)} rolls #{event[:perception_roll]} on perception"
    },

                      death_save: lambda { |event|
      output t("event.death_save", name: show_name(event), roll: event[:roll].to_s, value: event[:roll].result,
                                   saves: event[:saves], fails: event[:fails]).colorize(:blue)
    },

                      death_fail: lambda { |event|
      if event[:roll]
        output t("event.death_fail", name: show_name(event), roll: event[:roll].to_s, value: event[:roll].result,
                                     saves: event[:saves], fails: event[:fails]).colorize(:red)
      else
        output t("event.death_fail_hit", name: show_name(event), saves: event[:saves],
                                         fails: event[:fails]).colorize(:red)
      end
    },
                      great_weapon_fighting_roll: lambda { |event|
      output t("event.great_weapon_fighting_roll", name: show_name(event),
                                                   roll: event[:roll], prev_roll: event[:prev_roll])
    },
                      feature_protection: lambda { |event|
      output t("event.feature_protection", source: event[:source]&.name,
                                           target: event[:target]&.name, attacker: event[:attacker]&.name)
    },
                      prone: lambda { |event|
      output t("event.status.prone", name: show_name(event))
    },

                      stand: lambda { |event|
      output t("event.status.stand", name: show_name(event))
    },

                      %i[acrobatics athletics] => lambda { |event|
      if event[:success]
        output t("event.#{event[:event]}.success", name: show_name(event), roll: event[:roll],
                                                   value: event[:roll].result)
      else
        output t("event.#{event[:event]}.failure", name: show_name(event), roll: event[:roll],
                                                   value: event[:roll].result)
      end
    },

                      start_of_combat: lambda { |event|
      prompt.keypress(t("event.combat_start").colorize(:red))
      event[:combat_order].each_with_index do |entity_and_initiative, index|
        entity, initiative = entity_and_initiative
        output "#{index + 1}. #{decorate_name(entity)} #{initiative}"
      end
    },
                      spell_buff: lambda { |event|
      output t("event.spell_buff", source: show_name(event), spell: event[:spell].label,
                                   target: event[:target]&.name)
    },
                      end_of_combat: lambda { |_event|
      output t("event.combat_end")
    },
                      grapple_success: lambda { |event|
      if event[:target_roll]
        output t("event.grapple_success",
                 source: show_name(event), target: event[:target]&.name,
                 source_roll: event[:source_roll],
                 source_roll_value: event[:source_roll].result,
                 target_roll: event[:target_roll],
                 target_roll_value: event[:target_roll].result)
      else
        output t("event.grapple_success_no_roll",
                 source: show_name(event), target: event[:target]&.name)
      end
    },
                      first_aid: lambda { |event|
      output t("event.first_aid", name: show_name(event),
                                  target: event[:target]&.name, roll: event[:roll], value: event[:roll].result)
    },
                      first_aid_failure: lambda { |event|
      output t("event.first_aid_failure", name: show_name(event),
                                          target: event[:target]&.name, roll: event[:roll], value: event[:roll].result)
    },
                      grapple_failure: lambda { |event|
      output t("event.grapple_failure",
               source: show_name(event), target: event[:target]&.name,
               source_roll: event[:source_roll],
               source_roll_value: event[:source_roll].result,
               target_roll: event[:target_roll],
               target_roll_value: event[:target_roll_value].result)
    },
                      drop_grapple: lambda { |event|
      output t("event.drop_grapple",
               source: show_name(event), target: event[:target]&.name)
    },
                      flavor: lambda { |event|
      output t("event.flavor.#{event[:text]}", source: event[:source]&.name,
                                               target: event[:target]&.name)
    },
                      shove_success: lambda do |event|
      opts = {
        source: event[:source]&.name, target: event[:target]&.name,
        source_roll: event[:source_roll],
        source_roll_value: event[:source_roll].result,
        target_roll: event[:target_roll],
        target_roll_value: event[:target_roll].result,
      }
      if event[:knock_prone]
        output t("event.knock_prone_success", opts)
      else
        output t("event.shove_success", opts)
      end
    end,
                      shove_failure: lambda do |event|
      opts = {
        source: event[:source]&.name, target: event[:target]&.name,
        source_roll: event[:source_roll],
        source_roll_value: event[:source_roll].result,
        target_roll: event[:target_roll],
        target_roll_value: event[:target_roll].result,
      }
      if event[:knock_prone]
        output t("event.knock_prone_failure", opts)
      else
        output t("event.shove_failure", opts)
      end
    end,
                      %i[escape_grapple_success escape_grapple_failure] => lambda { |event|
      output t("event.#{event[:event]}",
               source: show_name(event), target: event[:target]&.name,
               source_roll: event[:source_roll],
               source_roll_value: event[:source_roll].result,
               target_roll: event[:target_roll],
               target_roll_value: event[:target_roll].result)
    } }
    event_handlers.each do |k, v|
      Natural20::EventManager.register_event_listener(k, v)
    end
  end

  def output(message)
    @logger.output(escape_to_html(message))
  end

  def escape_to_html(text)
    # Replace ANSI escape codes with HTML span tags
    html_text = text.gsub(/\x1b\[([0-9;]+)m/) do |match|
        codes = $1.split(';')

        case codes.last
        when "32" then '<span style="color:green;">'
        when "31" then '<span style="color:red;">'
        # Add more color codes as needed
        else
            ''
        end
    end

    # Close span tags for each opened tag
    html_text.gsub!('[0m', '</span>')

    html_text
  end

  def show_name(event)
      decorate_name(event[:source])
  end

  # @param event [Hash]
  def decorate_name(entity)
      "<b>#{entity.name}</b>"
  end

  def t(token, options = {})
    I18n.t(token, **options)
  end
end