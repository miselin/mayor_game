defmodule MayorGame.CityCalculator do
  use GenServer, restart: :permanent
  alias MayorGame.{City, CityHelpersTwo, Repo}
  # alias MayorGame.City.Details

  def start_link(initial_val) do
    IO.puts('start_city_calculator_link')
    # starts link based on this file
    # which triggers init function in module

    # check here if world exists already
    case City.get_world(initial_val) do
      %City.World{} -> IO.puts("world exists already!")
      nil -> City.create_world(%{day: 0, pollution: 0})
    end

    # this calls init function
    GenServer.start_link(__MODULE__, initial_val)
  end

  def init(initial_world) do
    IO.puts('init')
    # initial_val is 1 here, set in application.ex then started with start_link

    game_world = City.get_world!(initial_world)
    IO.inspect(game_world)

    # send message :tax to self process after 5000ms
    # calls `handle_info` function
    Process.send_after(self(), :tax, 5000)

    # returns ok tuple when u start
    {:ok, game_world}
  end

  # when :tax is sent
  def handle_info(:tax, world) do
    cities = City.list_cities_preload()
    cities_count = Enum.count(cities)

    pollution_ceiling =
      cities_count * 10000_000 +
        10000_000 * Random.gammavariate(7.5, 1)

    db_world = City.get_world!(1)

    IO.puts(
      "day: " <>
        to_string(db_world.day) <>
        " | cities: " <>
        to_string(cities_count) <>
        " | pollution: " <>
        to_string(db_world.pollution) <> " | —————————————————————————————————————————————"
    )

    cities_list = if rem(db_world.day, 2) == 1, do: Enum.reverse(cities), else: cities

    # result is map %{cities_w_room: [], citizens_looking: [], citizens_to_reproduce: [], etc}
    # FIRST ROUND CHECK
    # go through all cities
    # could try flowing this
    leftovers =
      Enum.reduce(
        cities_list,
        %{
          # all_cities: [],
          all_cities_new: [],
          citizens_looking: [],
          citizens_out_of_room: [],
          citizens_learning: %{0 => [], 1 => [], 2 => [], 3 => [], 4 => [], 5 => []},
          citizens_too_old: [],
          citizens_polluted: [],
          citizens_to_reproduce: [],
          new_world_pollution: 0,
          housed_unemployed_citizens: [],
          housed_employed_looking_citizens: [],
          unhoused_citizens: [],
          housing_slots: %{},
          housing_raw: %{}
        },
        fn city, acc ->
          # result here is a %Town{} with stats calculated
          # city_with_stats = MayorGame.CityHelpers.calculate_city_stats(city, db_world)

          city_with_stats2 =
            CityHelpersTwo.calculate_city_stats(
              city,
              db_world,
              cities_count,
              pollution_ceiling
            )

          # city_calculated_values =
          #   CityHelpers.calculate_stats_based_on_citizens(
          #     city_with_stats,
          #     db_world,
          #     cities_count
          #   )

          # should i loop through citizens here, instead of in calculate_city_stats?
          # that way I can use the same function later?

          # updated_city_treasury =
          #   if city_with_stats2.money < 0,
          #     do: 0,
          #     else: city_with_stats2.money

          # # check here for if tax_income - money is less than zero
          # # TODO: move this outside the enum to a multi update
          # case City.update_details(city.details, %{
          #        city_treasury: updated_city_treasury,
          #        pollution: city_with_stats2.pollution
          #      }) do
          #   {:ok, updated_details} ->
          #     nil

          #   {:error, err} ->
          #     IO.inspect(err)
          # end

          citizens_looking =
            city_with_stats2.housed_unemployed_citizens ++
              city_with_stats2.housed_employed_looking_citizens

          housing_slots = city_with_stats2.housing_left

          # + length(city_with_stats2.housed_unemployed_citizens) + length(city_with_stats2.housed_employed_looking_citizens)

          %{
            all_cities_new: [city_with_stats2 | acc.all_cities_new],
            # all_cities: [city_calculated_values | acc.all_cities],
            citizens_too_old: city_with_stats2.old_citizens ++ acc.citizens_too_old,
            citizens_learning:
              Map.merge(city_with_stats2.educated_citizens, acc.citizens_learning, fn _k,
                                                                                      v1,
                                                                                      v2 ->
                v1 ++ v2
              end),
            citizens_polluted: city_with_stats2.polluted_citizens ++ acc.citizens_polluted,
            citizens_to_reproduce:
              city_with_stats2.reproducing_citizens ++ acc.citizens_to_reproduce,
            citizens_out_of_room: city_with_stats2.unhoused_citizens ++ acc.citizens_out_of_room,
            citizens_looking: citizens_looking ++ acc.citizens_looking,
            new_world_pollution: city_with_stats2.pollution + acc.new_world_pollution,
            housed_unemployed_citizens:
              city_with_stats2.housed_unemployed_citizens ++ acc.housed_unemployed_citizens,
            housed_employed_looking_citizens:
              city_with_stats2.housed_employed_looking_citizens ++
                acc.housed_employed_looking_citizens,
            unhoused_citizens: city_with_stats2.unhoused_citizens ++ acc.unhoused_citizens,
            housing_slots:
              if(housing_slots > 0,
                do: Map.put(acc.housing_slots, city_with_stats2, housing_slots),
                else: acc.housing_slots
              ),
            housing_raw:
              if(city_with_stats2.housing_left > 0,
                do: Map.put(acc.housing_raw, city_with_stats2, city_with_stats2.housing_left),
                else: acc.housing_raw
              )
          }
        end
      )

    IO.inspect(length(Map.keys(leftovers.housing_slots)), label: "housing_left")

    # ok so here each city has

    pollution_max = Enum.max(Enum.map(leftovers.all_cities_new, &nil_value_check(&1, :pollution)))
    fun_max = Enum.max(Enum.map(leftovers.all_cities_new, &nil_value_check(&1, :fun)))
    health_max = Enum.max(Enum.map(leftovers.all_cities_new, &nil_value_check(&1, :health)))
    sprawl_max = Enum.max(Enum.map(leftovers.all_cities_new, &nil_value_check(&1, :sprawl)))

    # ——————————————————————————————————————————————————————————————————————————————————
    # ————————————————————————————————————————— ROUND 1: MOVE CITIZENS PER JOB LEVEL
    # ——————————————————————————————————————————————————————————————————————————————————

    level_slots =
      Map.new(0..5, fn x -> {x, %{normalized_cities: [], total_slots: 0, slots_expanded: []}} end)

    # sets up empty map for below function

    # SHAPE OF BELOW:
    # %{
    #   1: %{normalized_cities: [
    #     {city_normalized, # of slots}, {city_normalized, # of slots}
    #   ],
    #     total_slots: int,
    #     slots_expanded: list of slots
    #   }
    # }

    job_and_housing_slots_normalized =
      Enum.reduce(leftovers.housing_slots, level_slots, fn {city, slots_count}, acc ->
        normalized_city = normalize_city(city, fun_max, health_max, pollution_max, sprawl_max)

        # this should look like
        # %{
        #   0 => {normalized_city, count}
        # }
        slots_per_level =
          Enum.reduce(city.jobs, %{slots_count: slots_count}, fn {level, count}, acc2 ->
            if acc2.slots_count > 0 do
              level_slots_count = min(count, slots_count)

              acc2
              |> Map.update!(
                :slots_count,
                &(&1 - level_slots_count)
              )
              |> Map.put(level, {normalized_city, level_slots_count})
            else
              acc2
              |> Map.put(level, {normalized_city, 0})
            end
          end)
          |> Map.drop([:slots_count])

        # for each level in slots_per_level
        #
        acc
        |> Map.update!(0, fn current ->
          current
          |> Map.update!(:normalized_cities, &(&1 ++ [slots_per_level[0]]))
          |> Map.update!(:total_slots, &(&1 + elem(slots_per_level[0], 1)))
          |> Map.update!(:slots_expanded, fn current_expanded_slots ->
            current_expanded_slots ++ Enum.map(1..elem(slots_per_level[0], 1), fn _ -> city end)
          end)
        end)
        |> Map.update!(1, fn current ->
          current
          |> Map.update!(:normalized_cities, &(&1 ++ [slots_per_level[1]]))
          |> Map.update!(:total_slots, &(&1 + elem(slots_per_level[1], 1)))
          |> Map.update!(:slots_expanded, fn current_expanded_slots ->
            current_expanded_slots ++ Enum.map(1..elem(slots_per_level[1], 1), fn _ -> city end)
          end)
        end)
        |> Map.update!(2, fn current ->
          current
          |> Map.update!(:normalized_cities, &(&1 ++ [slots_per_level[2]]))
          |> Map.update!(:total_slots, &(&1 + elem(slots_per_level[2], 1)))
          |> Map.update!(:slots_expanded, fn current_expanded_slots ->
            current_expanded_slots ++ Enum.map(1..elem(slots_per_level[2], 1), fn _ -> city end)
          end)
        end)
        |> Map.update!(3, fn current ->
          current
          |> Map.update!(:normalized_cities, &(&1 ++ [slots_per_level[3]]))
          |> Map.update!(:total_slots, &(&1 + elem(slots_per_level[3], 1)))
          |> Map.update!(:slots_expanded, fn current_expanded_slots ->
            current_expanded_slots ++ Enum.map(1..elem(slots_per_level[3], 1), fn _ -> city end)
          end)
        end)
        |> Map.update!(4, fn current ->
          current
          |> Map.update!(:normalized_cities, &(&1 ++ [slots_per_level[4]]))
          |> Map.update!(:total_slots, &(&1 + elem(slots_per_level[4], 1)))
          |> Map.update!(:slots_expanded, fn current_expanded_slots ->
            current_expanded_slots ++ Enum.map(1..elem(slots_per_level[4], 1), fn _ -> city end)
          end)
        end)
        |> Map.update!(5, fn current ->
          current
          |> Map.update!(:normalized_cities, &(&1 ++ [slots_per_level[5]]))
          |> Map.update!(:total_slots, &(&1 + elem(slots_per_level[5], 1)))
          |> Map.update!(:slots_expanded, fn current_expanded_slots ->
            current_expanded_slots ++ Enum.map(1..elem(slots_per_level[5], 1), fn _ -> city end)

            # duplicate this score v times (1 for each slot)
          end)
        end)
      end)

    # job_and_housing_slots_normalized =
    #   Enum.map(level_slots, fn {level, map} ->
    #     total_slots =
    #       Enum.reduce(leftovers.housing_slots, 0, fn {k, v}, acc ->
    #         acc + min(v, k.jobs[level])
    #       end)

    #     normalized_cities =
    #       Enum.map(leftovers.housing_slots, fn {k, v} ->
    #         {normalize_city(k, fun_max, health_max, pollution_max, sprawl_max),
    #          min(v, k.jobs[level])}
    #       end)

    #     {level,
    #      map
    #      |> Map.put(:normalized_cities, normalized_cities)
    #      |> Map.put(:total_slots, total_slots)
    #      |> Map.put(
    #        :slots_expanded,
    #        Enum.flat_map(normalized_cities, fn {k, v} ->
    #          # duplicate this score v times (1 for each slot)

    #          for _ <- 1..v,
    #              do: k
    #        end)
    #      )}
    #   end)
    #   |> Enum.into(%{})

    citizens_split =
      Map.new(0..5, fn x ->
        {x,
         Enum.split(
           Enum.filter(leftovers.citizens_looking, fn cit -> cit.education == x end),
           job_and_housing_slots_normalized[x].total_slots
         )}
      end)

    # split looking

    preference_maps_by_level =
      Map.new(0..5, fn x ->
        {x,
         Enum.map(
           elem(citizens_split[x], 0),
           fn citizen ->
             Enum.flat_map(job_and_housing_slots_normalized[x].normalized_cities, fn {k, v} ->
               # duplicate this score v times (1 for each slot)

               score =
                 Float.round(1 - citizen_score(citizen.preferences, citizen.education, k), 4)

               for _ <- 1..v,
                   do: score
             end)
           end
         )}
      end)

    looking_but_not_in_job_race =
      Enum.reduce(citizens_split, [], fn {_k, v}, acc ->
        acc ++ elem(v, 1)
      end)

    # array of citizens who are still looking, that didn't make it into the level-specific comparisons

    # if not empty
    # run hungarian
    #
    hungarian_results_by_level =
      Map.new(0..5, fn x ->
        {x,
         if(preference_maps_by_level[x] != [],
           do: Hungarian.compute(preference_maps_by_level[x]),
           else: []
         )}
      end)

    # MULTI CHANGESET MOVE JOB SEARCHING CITIZENS
    # MOVE CITIZENS
    Enum.map(0..5, fn x ->
      if hungarian_results_by_level[x] != [] do
        hungarian_results_by_level[x]
        |> Enum.reduce(Ecto.Multi.new(), fn {citizen_index, slot_index}, multi ->
          citizen = Enum.at(elem(citizens_split[x], 0), citizen_index)
          town_from = City.get_town!(citizen.town_id)

          town_to =
            City.get_town!(
              Enum.at(job_and_housing_slots_normalized[x].slots_expanded, slot_index).id
            )

          if town_from.id != town_to.id do
            citizen_changeset =
              citizen
              |> City.Citizens.changeset(%{town_id: town_to.id, town: town_to})

            log_from =
              CityHelpersTwo.describe_citizen(citizen) <>
                " has moved to " <> town_to.title

            log_to =
              CityHelpersTwo.describe_citizen(citizen) <>
                " has moved from " <> town_from.title

            # if list is longer than 50, remove last item
            limited_log_from = update_logs(log_from, town_from.logs)
            limited_log_to = update_logs(log_to, town_to.logs)

            town_from_changeset =
              town_from
              |> City.Town.changeset(%{logs: limited_log_from})

            town_to_changeset =
              town_to
              |> City.Town.changeset(%{logs: limited_log_to})

            Ecto.Multi.update(multi, {:update_citizen_town, citizen_index}, citizen_changeset)
            |> Ecto.Multi.update({:update_town_from, citizen_index}, town_from_changeset)
            |> Ecto.Multi.update({:update_town_to, citizen_index}, town_to_changeset)
          else
            multi
          end
        end)
        |> Repo.transaction()
      end
    end)

    # ——————————————————————————————————————————————————————————————————————————————————
    # ————————————————————————————————————————— ROUND 2: MOVE CITIZENS ANYWHERE THERE IS HOUSING
    # ——————————————————————————————————————————————————————————————————————————————————

    # this produces a list of cities that have been occupied
    occupied_slots =
      Enum.flat_map(hungarian_results_by_level, fn {level, results_list} ->
        Enum.map(results_list, fn {_citizen_id, city_id} ->
          Enum.at(job_and_housing_slots_normalized[level].slots_expanded, city_id)

          # could also potentially move the citizens here
          # could move citizens here
          # COULD MOVE CITIZENS HERE ———————————————————————————————————
        end)
      end)

    # take housing slots, remove any city that was occupied previously
    slots_after_job_migrations =
      if leftovers.housing_slots == %{} do
        %{}
      else
        Enum.reduce(occupied_slots, leftovers.housing_slots, fn city, acc ->
          # need to find the right key, these cities are already normalized
          if is_nil(city) do
            acc
          else
            key = Enum.find(Map.keys(acc), fn x -> x.id == city.id end)
            Map.update!(acc, key, &(&1 - 1))
          end
        end)
      end

    housing_slots_normalized =
      Enum.map(slots_after_job_migrations, fn {k, v} ->
        {normalize_city(k, fun_max, health_max, pollution_max, sprawl_max), v}
      end)

    housing_slots_expanded =
      Enum.flat_map(housing_slots_normalized, fn {k, v} ->
        # duplicate this score v times (1 for each slot)

        for _ <- 1..v,
            do: k
      end)

    preference_maps =
      Enum.map(looking_but_not_in_job_race, fn citizen ->
        Enum.flat_map(housing_slots_normalized, fn {k, v} ->
          # duplicate this score v times (1 for each slot)

          score = Float.round(1 - citizen_score(citizen.preferences, citizen.education, k), 4)

          for _ <- 1..v,
              do: score
        end)
      end)

    hungarian_results = if preference_maps != [], do: Hungarian.compute(preference_maps), else: []

    # MULTI CHANGESET MOVE LOOKING CITIZENS
    # MOVE CITIZENS
    if hungarian_results != [] do
      hungarian_results
      |> Enum.reduce(Ecto.Multi.new(), fn {citizen_index, slot_index}, multi ->
        citizen = Enum.at(looking_but_not_in_job_race, citizen_index)
        town_from = City.get_town!(citizen.town_id)
        town_to = City.get_town!(Enum.at(housing_slots_expanded, slot_index).id)

        if town_from.id != town_to.id do
          citizen_changeset =
            citizen
            |> City.Citizens.changeset(%{town_id: town_to.id, town: town_to})

          log_from =
            CityHelpersTwo.describe_citizen(citizen) <>
              " has moved to " <> town_to.title

          log_to =
            CityHelpersTwo.describe_citizen(citizen) <>
              " has moved from " <> town_from.title

          # if list is longer than 50, remove last item
          limited_log_from = update_logs(log_from, town_from.logs)
          limited_log_to = update_logs(log_to, town_to.logs)

          town_from_changeset =
            town_from
            |> City.Town.changeset(%{logs: limited_log_from})

          town_to_changeset =
            town_to
            |> City.Town.changeset(%{logs: limited_log_to})

          Ecto.Multi.update(multi, {:update_citizen_town, citizen_index}, citizen_changeset)
          |> Ecto.Multi.update({:update_town_from, citizen_index}, town_from_changeset)
          |> Ecto.Multi.update({:update_town_to, citizen_index}, town_to_changeset)
        else
          multi
        end
      end)
      |> Repo.transaction()
    end

    # ——————————————————————————————————————————————————————————————————————————————————
    # ————————————————————————————————————————— ROUND 3: MOVE CITIZENS WITHOUT HOUSING ANYWHERE THERE IS HOUSING
    # ——————————————————————————————————————————————————————————————————————————————————

    occupied_slots_2 =
      Enum.map(hungarian_results, fn {_citizen_id, city_id} ->
        Enum.at(housing_slots_expanded, city_id)
      end)

    slots_after_housing_migrations =
      if slots_after_job_migrations == %{} do
        %{}
      else
        Enum.reduce(occupied_slots_2, slots_after_job_migrations, fn city, acc ->
          # need to find the right key, these cities are already normalized
          key = Enum.find(Map.keys(acc), fn x -> x.id == city.id end)
          Map.update!(acc, key, &(&1 - 1))
        end)
      end

    housing_slots_3_normalized =
      Enum.map(slots_after_housing_migrations, fn {k, v} ->
        {normalize_city(k, fun_max, health_max, pollution_max, sprawl_max), v}
      end)

    housing_slots_3_expanded =
      Enum.flat_map(housing_slots_3_normalized, fn {k, v} ->
        # duplicate this score v times (1 for each slot)

        for _ <- 1..v,
            do: k
      end)

    unhoused_split =
      Enum.shuffle(leftovers.unhoused_citizens) |> Enum.split(length(housing_slots_3_expanded))

    IO.inspect(length(leftovers.unhoused_citizens), label: 'unhoused citizens')

    unhoused_preference_maps =
      Enum.map(elem(unhoused_split, 0), fn citizen ->
        Enum.flat_map(housing_slots_normalized, fn {k, v} ->
          # duplicate this score v times (1 for each slot)

          score = Float.round(1 - citizen_score(citizen.preferences, citizen.education, k), 4)

          for _ <- 1..v,
              do: score
        end)
      end)

    hungarian_results_unhoused =
      if unhoused_preference_maps != [], do: Hungarian.compute(unhoused_preference_maps), else: []

    if hungarian_results_unhoused != [] do
      hungarian_results_unhoused
      |> Enum.reduce(Ecto.Multi.new(), fn {citizen_index, slot_index}, multi ->
        citizen = Enum.at(elem(unhoused_split, 0), citizen_index)
        town_from = City.get_town!(citizen.town_id)
        town_to = City.get_town!(Enum.at(housing_slots_3_expanded, slot_index).id)

        if town_from.id != town_to.id do
          citizen_changeset =
            citizen
            |> City.Citizens.changeset(%{town_id: town_to.id, town: town_to})

          log_from =
            CityHelpersTwo.describe_citizen(citizen) <>
              " has moved to " <> town_to.title

          log_to =
            CityHelpersTwo.describe_citizen(citizen) <>
              " has moved from " <> town_from.title

          # if list is longer than 50, remove last item
          limited_log_from = update_logs(log_from, town_from.logs)
          limited_log_to = update_logs(log_to, town_to.logs)

          town_from_changeset =
            town_from
            |> City.Town.changeset(%{logs: limited_log_from})

          town_to_changeset =
            town_to
            |> City.Town.changeset(%{logs: limited_log_to})

          Ecto.Multi.update(multi, {:update_citizen_town, citizen_index}, citizen_changeset)
          |> Ecto.Multi.update({:update_town_from, citizen_index}, town_from_changeset)
          |> Ecto.Multi.update({:update_town_to, citizen_index}, town_to_changeset)
        else
          multi
        end
      end)
      |> Repo.transaction()
    end

    # MULTI KILL REST OF UNHOUSED CITIZENS
    elem(unhoused_split, 1)
    |> Enum.with_index()
    |> Enum.reduce(Ecto.Multi.new(), fn {citizen, idx}, multi ->
      town = City.get_town!(citizen.town_id)

      log =
        CityHelpersTwo.describe_citizen(citizen) <>
          " has died because of a lack of housing. RIP"

      limited_log = update_logs(log, town.logs)

      town_changeset =
        town
        |> City.Town.changeset(%{logs: limited_log})

      Ecto.Multi.delete(multi, {:delete, idx}, citizen)
      |> Ecto.Multi.update({:update, idx}, town_changeset)
    end)
    |> Repo.transaction()

    #

    # unhoused_citizens (no anything)

    # ——————————————————————————————————————————————————————————————————————————————————
    # ————————————————————————————————————————— OTHER ECTO UPDATES
    # ——————————————————————————————————————————————————————————————————————————————————

    # MULTI UPDATE: update city money/treasury in DB
    leftovers.all_cities_new
    |> Enum.with_index()
    |> Enum.reduce(Ecto.Multi.new(), fn {city, idx}, multi ->
      updated_city_treasury =
        if city.money < 0,
          do: 0,
          else: city.money

      details_update_changeset =
        city.details
        |> City.Details.changeset(%{
          city_treasury: updated_city_treasury,
          pollution: city.pollution
        })

      Ecto.Multi.update(multi, {:update_towns, idx}, details_update_changeset)
    end)
    |> Repo.transaction()

    # MULTI CHANGESET EDUCATE

    leftovers.citizens_learning
    |> Enum.map(fn {level, list} ->
      list
      |> Enum.with_index()
      |> Enum.reduce(Ecto.Multi.new(), fn {citizen, idx}, multi ->
        town = City.get_town!(citizen.town_id)

        log =
          CityHelpersTwo.describe_citizen(citizen) <>
            " has graduated to level " <> to_string(level)

        # if list is longer than 50, remove last item
        limited_log = update_logs(log, town.logs)

        citizen_changeset =
          citizen
          |> City.Citizens.changeset(%{education: level})

        town_changeset =
          town
          |> City.Town.changeset(%{logs: limited_log})

        Ecto.Multi.update(multi, {:update_citizen_edu, idx}, citizen_changeset)
        |> Ecto.Multi.update({:update_town_log, idx}, town_changeset)
      end)
      |> Repo.transaction()
    end)

    # MULTI CHANGESET AGE
    Repo.update_all(MayorGame.City.Citizens, inc: [age: 1])

    # MULTI CHANGESET KILL OLD CITIZENS
    leftovers.citizens_too_old
    |> Enum.with_index()
    |> Enum.reduce(Ecto.Multi.new(), fn {citizen, idx}, multi ->
      town = City.get_town!(citizen.town_id)

      log = CityHelpersTwo.describe_citizen(citizen) <> " has died because of old age. RIP"

      # if list is longer than 50, remove last item
      limited_log = update_logs(log, town.logs)

      town_changeset =
        town
        |> City.Town.changeset(%{logs: limited_log})

      Ecto.Multi.delete(multi, {:delete, idx}, citizen)
      |> Ecto.Multi.update({:update, idx}, town_changeset)
    end)
    |> Repo.transaction()

    # MULTI KILL POLLUTED CITIZENS
    leftovers.citizens_polluted
    |> Enum.with_index()
    |> Enum.reduce(Ecto.Multi.new(), fn {citizen, idx}, multi ->
      town = City.get_town!(citizen.town_id)

      log =
        CityHelpersTwo.describe_citizen(citizen) <>
          " has died because of pollution. RIP"

      limited_log = update_logs(log, town.logs)

      town_changeset =
        town
        |> City.Town.changeset(%{logs: limited_log})

      Ecto.Multi.delete(multi, {:delete, idx}, citizen)
      |> Ecto.Multi.update({:update, idx}, town_changeset)
    end)
    |> Repo.transaction()

    # MULTI REPRODUCE
    leftovers.citizens_to_reproduce
    |> Enum.with_index()
    |> Enum.reduce(Ecto.Multi.new(), fn {citizen, idx}, multi ->
      town = City.get_town!(citizen.town_id)

      log =
        CityHelpersTwo.describe_citizen(citizen) <>
          " had a child"

      limited_log = update_logs(log, town.logs)
      # if list is longer than 50, remove last item

      changeset =
        City.create_citizens_changeset(%{
          money: 0,
          town_id: citizen.town_id,
          age: 0,
          education: 0,
          has_car: false,
          has_job: false,
          last_moved: db_world.day
        })

      town_changeset =
        town
        |> City.Town.changeset(%{logs: limited_log})

      Ecto.Multi.insert(multi, {:add_citizen, idx}, changeset)
      |> Ecto.Multi.update({:update, idx}, town_changeset)
    end)
    |> Repo.transaction()

    # CHECK —————
    # FOURTH CITIZEN CHECK: LOOKING FOR workers

    # if there are cities with room at all (if a city has room, this list won't be empty):
    # cities_after_job_search =
    #   Enum.reduce(leftovers.citizens_looking, leftovers.all_cities, fn citizen, acc_city_list ->
    #     cities_with_housing_and_workers =
    #       Enum.filter(acc_city_list, fn city -> city.available_housing > 0 end)
    #       |> Enum.filter(fn city ->
    #         Enum.any?(city.workers, fn {_level, number} -> number > 0 end)
    #       end)

    #     # results are map %{best_city: %{city: city, workers: #, housing: #, etc}, job_level: #}
    #     best_job = CityHelpers.find_best_job(cities_with_housing_and_workers, citizen)

    #     if !is_nil(best_job) do
    #       # move citizen to city

    #       # TODO: check last_moved date here
    #       # although this could result in looking citizens staying in a city even though there's no housing
    #       # may need to consolidate out of room and looking
    #       # this is where the stale structs keep getting hit
    #       CityHelpers.move_citizen(citizen, City.get_town!(best_job.best_city.id), db_world.day)

    #       # find where the city is in the list
    #       indexx = Enum.find_index(acc_city_list, &(&1.id == best_job.best_city.id))

    #       # make updated list, decrement housing and workers
    #       updated_acc_city_list =
    #         List.update_at(acc_city_list, indexx, fn update ->
    #           update
    #           |> Map.update!(:available_housing, &(&1 - 1))
    #           |> update_in([:workers, best_job.job_level], &(&1 - 1))
    #         end)

    #       updated_acc_city_list
    #     else
    #       acc_city_list
    #     end
    #   end)

    # # ok, available housing looks right here

    # # CHECK —————
    # # LAST CITIZEN CHECK: OUT OF ROOM
    # Enum.reduce(leftovers.citizens_out_of_room, cities_after_job_search, fn citizen_out_of_room,
    #                                                                         acc_city_list ->
    #   cities_with_housing = Enum.filter(acc_city_list, fn city -> city.available_housing > 0 end)

    #   best_job = CityHelpers.find_best_job(cities_with_housing, citizen_out_of_room)

    #   if !is_nil(best_job) do
    #     # move citizen to city

    #     # TODO: check last_moved date here
    #     # although this could result in looking citizens staying in a city even though there's no housing
    #     # may need to consolidate out of room and looking
    #     CityHelpers.move_citizen(
    #       citizen_out_of_room,
    #       City.get_town!(best_job.best_city.id),
    #       db_world.day
    #     )

    #     # find where the city is in the list
    #     indexx = Enum.find_index(acc_city_list, &(&1.id == best_job.best_city.id))

    #     # make updated list, decrement housing and workers
    #     updated_acc_city_list =
    #       List.update_at(acc_city_list, indexx, fn update ->
    #         update
    #         |> Map.update!(:available_housing, &(&1 - 1))
    #         |> update_in([:workers, best_job.job_level], &(&1 - 1))
    #       end)

    #     updated_acc_city_list

    #     # if no best job
    #   else
    #     # if there's any cities with housing left
    #     if cities_with_housing != [] do
    #       CityHelpers.move_citizen(
    #         citizen_out_of_room,
    #         City.get_town!(hd(cities_with_housing).id),
    #         db_world.day
    #       )

    #       # find where the city is in the list
    #       indexx = Enum.find_index(acc_city_list, &(&1.id == hd(cities_with_housing).id))

    #       # make updated list, decrement housing and workers
    #       updated_acc_city_list =
    #         List.update_at(acc_city_list, indexx, fn update ->
    #           update
    #           |> Map.update!(:available_housing, &(&1 - 1))
    #         end)

    #       updated_acc_city_list
    #     else
    #       # find where the city is in the list
    #       indexx = Enum.find_index(acc_city_list, &(&1.id == citizen_out_of_room.town_id))

    #       # make updated list, decrement housing
    #       updated_acc_city_list =
    #         List.update_at(acc_city_list, indexx, fn update ->
    #           Map.update!(update, :available_housing, &(&1 + 1))
    #         end)

    #       CityHelpers.kill_citizen(citizen_out_of_room, "no housing available")

    #       updated_acc_city_list
    #     end
    #   end
    # end)

    updated_pollution =
      if db_world.pollution + leftovers.new_world_pollution < 0 do
        0
      else
        db_world.pollution + leftovers.new_world_pollution
      end

    # update World in DB, pull updated_world var out of response
    {:ok, updated_world} =
      City.update_world(db_world, %{
        day: db_world.day + 1,
        pollution: updated_pollution
      })

    # SEND RESULTS TO CLIENTS
    # send val to liveView process that manages front-end; this basically sends to every client.
    MayorGameWeb.Endpoint.broadcast!(
      "cityPubSub",
      "ping",
      updated_world
    )

    # recurse, do it again
    Process.send_after(self(), :tax, 5000)

    # returns this to whatever calls ?
    {:noreply, updated_world}
  end

  def update_logs(log, existing_logs) do
    updated_log = [log | existing_logs]

    if length(updated_log) > 50 do
      updated_log |> Enum.reverse() |> tl() |> Enum.reverse()
    else
      updated_log
    end
  end

  def nil_value_check(map, key) do
    if Map.has_key?(map, key), do: map[key], else: 0
  end

  def normalize_city(city, max_fun, max_health, max_pollution, max_sprawl) do
    %{
      city: city,
      id: city.id,
      sprawl_normalized: zero_check(nil_value_check(city, :sprawl), max_sprawl),
      pollution_normalized: zero_check(nil_value_check(city, :pollution), max_pollution),
      fun_normalized: zero_check(nil_value_check(city, :fun), max_fun),
      health_normalized: zero_check(nil_value_check(city, :health), max_health),
      tax_rates: city.tax_rates
    }
  end

  def zero_check(check, divisor) do
    if check == 0 or divisor == 0, do: 0, else: check / divisor
  end

  def citizen_score(citizen_preferences, education_level, normalized_city) do
    normalized_city.tax_rates[to_string(education_level)] * citizen_preferences["tax_rates"] +
      normalized_city.pollution_normalized * citizen_preferences["pollution"] +
      normalized_city.sprawl_normalized * citizen_preferences["sprawl"] +
      normalized_city.fun_normalized * citizen_preferences["fun"] +
      normalized_city.health_normalized * citizen_preferences["health"]
  end

  def mindotproduct(a, b), do: dotproduct(Enum.sort(a), Enum.sort(b))
  defp dotproduct([], []), do: 0
  defp dotproduct([ah | at] = _a, [bh | bt] = _b), do: ah * bh + dotproduct(at, bt)
end
