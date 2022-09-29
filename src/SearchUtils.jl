"""Functions to help with the main loop of SymbolicRegression.jl.

This includes: process management, stdin reading, checking for early stops."""
module SearchUtilsModule

import Printf: @printf, @sprintf
using Distributed

import ..CoreModule: SRThreaded, SRSerial, SRDistributed, Dataset, Options
import ..EquationUtilsModule: compute_complexity
import ..HallOfFameModule:
    HallOfFame, calculate_pareto_frontier, string_dominating_pareto_curve
import ..ProgressBarsModule: WrappedProgressBar, set_multiline_postfix

function next_worker(worker_assignment::Dict{Tuple{Int,Int},Int}, procs::Vector{Int})::Int
    job_counts = Dict(proc => 0 for proc in procs)
    for (key, value) in worker_assignment
        @assert haskey(job_counts, value)
        job_counts[value] += 1
    end
    least_busy_worker = reduce(
        (proc1, proc2) -> (job_counts[proc1] <= job_counts[proc2] ? proc1 : proc2), procs
    )
    return least_busy_worker
end

function next_worker(worker_assignment::Dict{Tuple{Int,Int},Int}, procs::Nothing)::Int
    return 0
end

macro sr_spawner(parallel, p, expr)
    quote
        if $(esc(parallel)) == SRSerial
            $(esc(expr))
        elseif $(esc(parallel)) == SRDistributed
            @spawnat($(esc(p)), $(esc(expr)))
        else
            Threads.@spawn($(esc(expr)))
        end
    end
end

struct StdinReader{ST}
    can_read_user_input::Bool
    stream::ST
end

"""Start watching stream (like stdin) for user input."""
function watch_stream(stream)
    can_read_user_input = true
    stream = stream
    try
        Base.start_reading(stream)
        bytes = bytesavailable(stream)
        if bytes > 0
            # Clear out initial data
            read(stream, bytes)
        end
    catch err
        if isa(err, MethodError)
            can_read_user_input = false
        else
            throw(err)
        end
    end
    return StdinReader(can_read_user_input, stream)
end

"""Check if the user typed 'q' and <enter> or <ctl-c>."""
function check_for_quit(reader::StdinReader)::Bool
    if reader.can_read_user_input
        bytes = bytesavailable(reader.stream)
        if bytes > 0
            # Read:
            data = read(reader.stream, bytes)
            control_c = 0x03
            quit = 0x71
            if length(data) > 1 && (data[end] == control_c || data[end - 1] == quit)
                return true
            end
        end
    end
    return false
end

"""Close the stdin reader and stop reading."""
function close_reader!(reader::StdinReader)
    if reader.can_read_user_input
        Base.stop_reading(reader.stream)
    end
end

function check_for_early_stop(
    options::Options,
    datasets::AbstractVector{Dataset{T}},
    hallOfFame::AbstractVector{HallOfFame{T}},
)::Bool where {T}
    options.earlyStopCondition === nothing && return false

    # Check if all nout are below stopping condition.
    for (dataset, hof) in zip(datasets, hallOfFame)
        dominating = calculate_pareto_frontier(dataset, hof, options)
        # Check if zero size:
        length(dominating) == 0 && return false

        stop_conditions = [
            options.earlyStopCondition(
                member.loss, compute_complexity(member.tree, options)
            ) for member in dominating
        ]
        if !(any(stop_conditions))
            return false
        end
    end
    return true
end

function update_progress_bar!(
    progress_bar::WrappedProgressBar;
    hall_of_fame::HallOfFame{T},
    dataset::Dataset{T},
    options::Options,
    head_node_occupation::Float64,
) where {T}
    equation_strings = string_dominating_pareto_curve(hall_of_fame, dataset, options)
    load_string = @sprintf("Head worker occupation: %.1f", head_node_occupation) * "%\n"
    # TODO - include command about "q" here.
    load_string *= @sprintf("Press 'q' and then <enter> to stop execution early.\n")
    equation_strings = load_string * equation_strings
    set_multiline_postfix(progress_bar.bar, equation_strings)
    cur_cycle = progress_bar.cycle
    cur_state = progress_bar.state
    if cur_cycle === nothing
        cur_cycle, cur_state = iterate(progress_bar.bar)
    else
        cur_cycle, cur_state = iterate(progress_bar.bar, cur_state)
    end
    progress_bar.cycle = cur_cycle
    progress_bar.state = cur_state
    return nothing
end

function print_search_state(
    hall_of_fames::Vector{HallOfFame{T}},
    datasets::Vector{Dataset{T}},
    options::Options;
    equation_speed::Vector{Float32},
    total_cycles::Int,
    cycles_remaining::Vector{Int},
    head_node_occupation::Float64,
) where {T}
    nout = length(datasets)
    average_speed = sum(equation_speed) / length(equation_speed)

    @printf("\n")
    @printf("Cycles per second: %.3e\n", round(average_speed, sigdigits=3))
    @printf("Head worker occupation: %.1f%%\n", head_node_occupation)
    cycles_elapsed = total_cycles * nout - sum(cycles_remaining)
    @printf(
        "Progress: %d / %d total iterations (%.3f%%)\n",
        cycles_elapsed,
        total_cycles * nout,
        100.0 * cycles_elapsed / total_cycles / nout
    )

    @printf("==============================\n")
    for (j, (hall_of_fame, dataset)) in enumerate(zip(hall_of_fames, datasets))
        if nout > 1
            @printf("Best equations for output %d\n", j)
        end
        equation_strings = string_dominating_pareto_curve(hall_of_fame, dataset, options)
        print(equation_strings)
        @printf("==============================\n")
    end
    @printf("Press 'q' and then <enter> to stop execution early.\n")
end

end
