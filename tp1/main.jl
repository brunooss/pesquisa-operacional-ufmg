using JuMP
using Gurobi
using JSON3

json_data = JSON3.read(read("buildings.json", String))

buildings = []


# for building in json_data
#     name = Symbol(lowercase(replace(replace(building.name, "'" => ""), " " => "_")))
#     # println("Construção: ", name, " tem id ", building.gid)
#     buildings[building.gid] = name
#     println(building.gid, " - ", buildings[building.gid])
# end

###########################################################################
##                                                                       ##
##  Parsing dos Dados                                                    ##
##                                                                       ##
###########################################################################


for building in json_data
    name = Symbol(lowercase(replace(replace(building.name, "'" => ""), " " => "_")))
    if building.category == "Military" && !(building.name == "Barracks" || building.name == "Rally Point")
        @goto cabou_predio
    end

    # Lê pré-requisitos
    if haskey(building, :prerequisites)
        for prereq in building.prerequisites
            if haskey(prereq, :type)
                if prereq.type == "Building"
                    # println("       Requer ", join(prereq.gid, " ou "), " no nivel ", prereq.level)
                elseif prereq.type == "NotBuilding"
                    # println("       Não pode ser junto do ", join(prereq.gid, " nem do "))
                elseif prereq.type == "NotCapital" || prereq.type == "Shore" || prereq.type == "StorageArtefact" || prereq.type == "WonderOfTheWorldVillage"
                    # remove os que não podemos construir.
                    @goto cabou_predio
                elseif prereq.type == "Tribe" && haskey(prereq, :vid)
                    if !(6 in prereq.vid)

                        # remove os que não podemos construir.
                        @goto cabou_predio
                    end
                elseif prereq.type == "Level11CapitalOrCity" || prereq.type == "Level13Capital" || prereq.type == "Capital"
                # else
                #     println("       Tipo: ", prereq.type)
                end
            # elseif haskey(prereq, :building)
            #     println("    Precisa de ", prereq.building, " nível ", prereq.level)
            end
        end
    end
    push!(buildings, building)
    @label cabou_predio
end












# ATENÇÃO: o código abaixo exibe cada prédio que estamos considerando e a dependência de cada um, já ajustadas para o problema.
#       Descomente-o para dar uma olhada!

# for building in buildings
#     println("Construção ", building.gid) # , name, "(", building.gid, ")")
#     if haskey(building, :prerequisites)
#         for prereq in building.prerequisites
#             if haskey(prereq, :type)
#                 if prereq.type == "Building"
#                     println("       Requer ", join(prereq.gid, " ou "), " no nivel ", prereq.level)
#                 elseif prereq.type == "NotBuilding"
#                     println("       Não pode ser junto do ", join(prereq.gid, " nem do "))
#                 end
#             end
#         end
#     end         
# end
#println("Foram adicionados ", length(buildings), " de ", length(json_data), " prédios.")






###########################################################################
##                                                                       ##
##  Modelo                                                               ##
##                                                                       ##
###########################################################################

total_time = 72 * 60 * 60 # 72 horas em segundos

# Primeiro, gerar os dados em estruturas separadas
struct BuildingLevel
    id::Int64
    name::String
    level::Int64
    buildingTime::Float64
    population::Int64
end

all_levels = BuildingLevel[]

# Define os níveis de cada prédio em sequência, como se cada nível fosse um prédio diferente
# A questão aqui é que só vai ter um "prédio diferente" para um mesmo "gid" (que representa um prédio no jogo)
for b in buildings
    name = b["name"]
    gid = b["gid"]
    if haskey(b, "levelData")
        for (lvl_str, lvl_data) in b["levelData"]
            lvl = lvl_data["level"]
            time = lvl_data["buildingTime"]
            pop = lvl_data["population"]
            push!(all_levels, BuildingLevel(gid, name, lvl, time, pop))
        end
    end
end
model = Model(Gurobi.Optimizer)

# Cria uma variável para cada prédio
@variable(model, x[1:length(all_levels)], Bin)


level_times = Vector{Float64}(undef, length(all_levels))
for (i, lvl) in enumerate(all_levels)
    name = lvl.name
    lvl_index = lvl.level

    # pegar todos os níveis menores ou iguais
    relevant = filter(x -> x.name == name && x.level <= lvl_index, all_levels)
    level_times[i] = sum(x.buildingTime for x in relevant)
end

@constraint(model, sum(x[i] * level_times[i] for i in 1:length(x)) <= total_time)


# Restrição: só pode escolher um nível por prédio
# Cria um dicionário com índices dos níveis de cada prédio
building_groups = Dict{String, Vector{Int}}()
for (i, lvl) in enumerate(all_levels)
    name = lvl.name
    push!(get!(building_groups, name, Int[]), i)
end

# Agora adiciona a restrição: no máximo um nível de cada prédio
for (bname, indices) in building_groups
    @constraint(model, sum(x[i] for i in indices) <= 1)
end

# Objetivo: maximizar população total (pode trocar por cultura se quiser)
@objective(model, Max, sum(x[i] * all_levels[i].population for i in 1:length(x)))

optimize!(model)

# println("Status: ", termination_status(model))
t = 0.0
for i in 1:length(all_levels)
    if value(x[i]) > 0.5
        lvl = all_levels[i]
        println("Construir: ", lvl.name, " nível ", lvl.level, 
                " (tempo acumulado: ", level_times[i], "s, pop: ", lvl.population, ")")
        global t += level_times[i]
    end
end

println("Tempo total: ", t, "s (", round(t / 3600, digits=2), " horas)")





















