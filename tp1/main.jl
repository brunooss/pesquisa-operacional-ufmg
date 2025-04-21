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
    cost::NTuple{4,Int} 
    production::Vector{Int64}
end

all_levels = BuildingLevel[]
prereq_map = Dict{Int, Vector{Any}}()

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
            
            rc = lvl_data["resourceCost"]
            costs = (rc["r1"], rc["r2"], rc["r3"], rc["r4"])

            production = [0, 0, 0, 0]

            if gid == 1
                production = [lvl_data["effects"]["production1"], 0, 0, 0]
            elseif gid == 2
                production = [0, lvl_data["effects"]["production2"], 0, 0]
            elseif gid == 3
                production = [0, 0, lvl_data["effects"]["production3"], 0]
            elseif gid == 4
                production = [0, 0, 0, lvl_data["effects"]["production4"]]
            end

            push!(all_levels, BuildingLevel(gid, name, lvl, time, pop, costs, production))
        end
    end

    if haskey(b, :prerequisites)
        prereq_map[b["gid"]] = b["prerequisites"]
    else
        prereq_map[b["gid"]] = Any[]  # sem pré‑requisitos
    end
end

n = length(all_levels)
T = 72                                     # horizonte em horas
MAX_SECONDS = 72*3600

# arredonda para horas (sempre pra cima)
build_hours = [ceil(Int, lvl.buildingTime/3600) for lvl in all_levels]

# índices de quais itens geram cada recurso r
fields_of = Dict(r => Int[] for r in 1:4)
for i in 1:n, r in 1:4
    if all_levels[i].production[r] > 0
        push!(fields_of[r], i)
    end
end

model = Model(Gurobi.Optimizer)

# 1) decisão de iniciar o nível i exatamente na hora t
@variable(model, x[1:n, 1:T], Bin)

# 2) indicador de “já construído até t” (built[i,t] = 1 se terminou <= t)
@variable(model, built[1:n, 0:T], Bin)

# 3) estoque disponível de cada recurso r em cada t
@variable(model, stock[1:4, 0:T] >= 0)

#
# ———————— Construção / Fila (até 2 simultâneas) ————————
#
# capacidade de slots egípcios
for t in 1:T
    @constraint(model,
        sum( x[i,τ] for i in 1:n, τ in max(1,t-build_hours[i]+1):t ) ≤ 2
    )
end

#
# ———————— “built” a partir de “x” ————————
#
# se você inicia i em τ e demora h horas, então built[i, t]=1 para todo t≥τ+h-1
for i in 1:n, t in 0:T
    if t == 0
        @constraint(model, built[i,0] == 0)
    else
        @constraint(model,
            built[i,t] == sum( x[i, τ]
                                for τ in 1:t
                                if τ + build_hours[i] - 1 ≤ t )
        )
    end
end

#
# ———————— Estoque dinâmico de recursos ————————
#
const INIT_RES = (750,750,750,750)
# estoque inicial em t=0
for r in 1:4
    @constraint(model, stock[r,0] == INIT_RES[r])
end

# evolução horária
for t in 1:T, r in 1:4
    @constraint(model,
      stock[r,t] == stock[r,t-1]
                   # produção horária de todos os fields prontos até t-1
                   + sum( all_levels[i].production[r] * built[i, t-1]
                          for i in fields_of[r] )
                   # menos o custo no instante de início (x[i,t])
                   - sum( all_levels[i].cost[r] * x[i,t]
                          for i in 1:n )
    )
    # nunca ultrapassar capacidade inicial de cada recurso
    @constraint(model, stock[r,t] ≥ 0)
end

#
# ———————— Só um nível por prédio ————————
#
groups = Dict{String,Vector{Int}}()
for (i,lvl) in enumerate(all_levels)
    push!( get!(groups, lvl.name, Int[]), i )
end
for idxs in values(groups)
    @constraint(model, sum(x[i, t] for i in idxs, t in 1:T) ≤ 1)
end

#
# ———————— Objetivo de exemplo (max pop) ————————
#
@objective(model, Max,
    sum( all_levels[i].population * built[i,T] for i in 1:n )
)

optimize!(model)

println("\n>>> Plano de Construção (início em horas, duração em horas) <<<")
    total_seconds = 0

    # Para cada prédio‑nível i e cada hora t, se x[i,t] = 1…
    for i in 1:n, t in 1:T
        if value(x[i, t]) > 0.5
            lvl = all_levels[i]
            # build_hours[i] já era ceil(time/3600)
            h_dur = build_hours[i]
            total_seconds += lvl.buildingTime

            println("– ", lvl.name,
                    " | nível ", lvl.level,
                    " | inicia em t=", t,
                    "h, dura ", h_dur, "h (", lvl.buildingTime, "s)",
                    " → pop +", lvl.population)
        end
    end

    println("\nTempo total de “obra” (soma de todos os tempos de construção):")
    println("   ", total_seconds, " segundos",
            " (≈", round(total_seconds/3600, digits=2), " horas)")












