module GarishPrint

export pprint

# 1.0 Compat
@static if !@isdefined(isnothing)
    isnothing(x) = x === nothing
end

"""
    tty_has_color()

Check if TTY supports color. This is mainly for lower
Julia version like 1.0.
"""
function tty_has_color()
    if isdefined(Base, :get_have_color)
        return Base.get_have_color()
    else
        return Base.have_color
    end
end

"""
    supports_color256()

Check if the terminal supports color 256.
"""
function supports_color256()
    haskey(ENV, "TERM") || return false
    try
        return parse(Int, readchomp(`tput colors 0`)) == 256
    catch
        return false
    end
end

const ColorType = Union{Int, Symbol}

"""
    ColorPreference

The color preference type.
"""
struct ColorPreference
    fieldname::ColorType
    type::ColorType
    operator::ColorType
    
    # literal-like
    literal::ColorType
    constant::ColorType
    number::ColorType
    string::ColorType

    # comment-like
    comment::ColorType
    undef::ColorType
    linenumber::ColorType
end

"""
    ColorPreference(;kw...)

See [`pprint`](@ref) for available keyword configurations.
"""
function ColorPreference(;kw...)
    default = supports_color256() ? default_colors_256() : default_colors_ansi()
    colors = merge(default, kw)
    return ColorPreference([colors[name] for name in fieldnames(ColorPreference)]...)
end

"""
    default_colors_ansi()

The default ANSI color theme.
"""
function default_colors_ansi()
    Dict(
        :fieldname => :light_blue,
        :type => :green,
        :operator => :normal,
        :literal => :yellow,
        :constant => :yellow,
        :number => :normal,
        :string => :yellow,
        :comment => :light_black,
        :undef => :normal,
        :linenumber => :light_black,
    )
end

"""
    default_colors_256()

The default color 256 theme.
"""
function default_colors_256()
    Dict(
        :fieldname => 039,
        :type => 037,
        :operator => 196,
        :literal => 140,
        :constant => 099,
        :number => 140,
        :string => 180,
        :comment => 240,
        # undef is actually a constant
        :undef => 099,
        :linenumber => 240,
    )
end

"""
    @enum PrintType

`PrintType` to tell lower level printing some useful context.
Currently only supports `Unknown` and `StructField`.
"""
@enum PrintType begin
    Unknown
    StructField
end

mutable struct PrintState
    type::PrintType
    noindent_in_first_line::Bool
    level::Int
    # the offset that should be applied
    # to whoever cares, e.g for the field
    # values
    offset::Int
end

PrintState() = PrintState(Unknown, false, 0, 0)

"""
    GarishIO{IO_t <: IO} <: IO

`GarishIO` contains the pretty printing preference and states.

# Members

- `bland_io::IO_t`: the original io.
- `indent::Int`: indentation size.
- `compact::Bool`: whether the printing should be compact.
- `displaysize::Tuple{Int, Int}`: the terminal displaysize.
- `show_indent`: print the indentation hint or not.
- `color`: color preference, either `ColorPreference` or `nothing` for no color.
- `state`: the state of the printer, see [`PrintState`](@ref).
"""
struct GarishIO{IO_t <: IO} <: IO
    # the bland io we want look nice
    bland_io::IO_t
    indent::Int
    compact::Bool
    displaysize::Tuple{Int, Int}
    show_indent::Bool
    # use nothing for no color print
    color::Union{Nothing, ColorPreference}
    state::PrintState
end

function wrap_io_context(io::GarishIO)
    IOContext(
        io.bland_io,
        :color=>isnothing(io.color),
        :compact=>io.compact,
        :displaysize=>io.displaysize,
    )
end

function _write(io::GarishIO, x)
    write(wrap_io_context(io), x)
end

"""
    within_nextlevel(f, io::GarishIO)

Run `f()` within the next level of indentation where `f` is a function
that print into `io`.
"""
function within_nextlevel(f, io::GarishIO)
    io.state.level += 1
    ret = f()
    io.state.level -= 1
    return ret
end

Base.write(io::GarishIO, x) = _write(io, x)
Base.write(io::GarishIO, x::UInt8) = _write(io, x)
Base.write(io::GarishIO, x::Char) = _write(io, x)
Base.write(io::GarishIO, x::Symbol) = _write(io, x)
Base.write(io::GarishIO, x::Array) = _write(io, x)
Base.write(io::GarishIO, x::AbstractArray) = _write(io, x)
Base.write(io::GarishIO, s::AbstractString) = _write(io, s)
Base.write(io::GarishIO, s::Union{SubString{String}, String}) = _write(io, s)

function Base.get(io::GarishIO, key::Symbol, default)
    if key === :indent
        return io.key
    elseif key === :compact
        return io.compact
    elseif key === :color
        return !isnothing(io.color)
    else
        return get(io.bland_io, key, default)
    end
end

"""
    GarishIO(io::IO; kw...)

See [`pprint`](@ref) for available keywords.
"""
function GarishIO(io::IO; 
        indent::Int=2,
        compact::Bool=get(io, :compact, false),
        displaysize::Tuple{Int, Int}=displaysize(io),
        show_indent::Bool=true,
        color::Bool=true,
        kw...
    )

    if color
        if get(io, :color, false) # force turn on color
            io = IOContext(io, :color=>true)
        end
        color_prefs = ColorPreference(;kw...)
    else
        if get(io, :color, true) # force turn off color
            io = IOContext(io, :color=>false)
        end
        color_prefs = nothing
    end
    return GarishIO(io, indent, compact, displaysize, show_indent, color_prefs, PrintState())
end

"""
    GarishIO(io::IO, garish_io::GarishIO; kw...)

Create a new similar `GarishIO` with new bland IO object `io`
based on an existing garish io preference. The preference can
be overloaded by `kw`. See [`pprint`](@ref) for the available
keyword arguments.
"""
function GarishIO(io::IO, garish_io::GarishIO;
        indent::Int=garish_io.indent, compact::Bool=garish_io.compact,
    )

    if haskey(io, :color) && io[:color] == false
        color = nothing
    else
        color = garish_io.color
    end
    
    GarishIO(
        io, indent, compact,
        garish_io.displaysize,
        garish_io.show_indent,
        color,
        garish_io.state
    )
end

"""
    print_token(io::GarishIO, type::Symbol, xs...)

Print `xs` to a `GarishIO` as given token type. The token type
should match the field name of `ColorPreference`.
"""
function print_token(io::GarishIO, type::Symbol, xs...)
    print_token(print, io, type, xs...)
end

"""
    print_token(f, io::GarishIO, type::Symbol, xs...)

Print `xs` to a `GarishIO` as given token type using `f(io, xs...)`
"""
function print_token(f, io::GarishIO, type::Symbol, xs...)
    isnothing(io.color) && return f(io, xs...)
    Base.with_output_color(f, getfield(io.color, type), io, xs...)
end

pprint(xs...; kw...) = pprint(stdout, xs...; kw...)

"""
    pprint([io::IO=stdout, ]xs...; kw...)

Pretty print given objects `xs` to `io`, default io is `stdout`.

# Keyword Arguments

- `indent::Int`: indent size, default is `2`.
- `compact::Bool`: whether print withint one line, default is `get(io, :compact, false)`.
- `displaysize::Tuple{Int, Int}`: the displaysize hint of printed string, note this is not stricted obeyed,
default is displaysize(io).
- `show_indent::Bool`: whether print indentation hint, default is `true`.
- `color::Bool`: whether print with color, default is `true`.

## Color Preference

color preference is available as keyword arguments to override the
default color scheme. These arguments may take any of the values
`:normal`, `:default`, `:bold`, `:black`, `:blink`, `:blue`,
`:cyan`, `:green`, `:hidden`, `:light_black`, `:light_blue`, `:light_cyan`, `:light_green`,
`:light_magenta`, `:light_red`, `:light_yellow`, `:magenta`, `:nothing`, `:red`, `:reverse`,
`:underline`, `:white`, or `:yellow` or an integer between 0 and 255 inclusive. Note that
not all terminals support 256 colors.

The default color scheme can be checked via `GarishPrint.default_colors_256()` for 256 color,
and `GarishPrint.default_colors_ansi()` for ANSI color. The 256 color will be used when
the terminal is detected to support 256 color.

- `fieldname`: field name of a struct.
- `type`: the color of a type.
- `operator`: the color of an operator, e.g `+`, `=>`.
- `literal`: the color of literals.
- `constant`: the color of constants, e.g `π`.
- `number`: the color of numbers, e.g `1.2`, `1`.
- `string`: the color of string.
- `comment`: comments, e.g `# some comments`
- `undef`: the const binding to `UndefInitializer`
- `linenumber`: line numbers.

# Notes

The color print and compact print can also be turned on/off by
setting `IOContext`, e.g `IOContext(io, :color=>false)` will print
without color, and `IOContext(io, :compact=>true)` will print within
one line. This is also what the standard Julia `IO` objects follows
in printing by default.
"""
function pprint(io::IO, xs...; kw...)
    lock(io)
    try
        for x in xs
            pprint(io, x; kw...)
        end
    finally
        unlock(io)
    end
    return nothing
end

pprint(io::IO, x; kw...) = pprint(io, MIME"text/plain"(), x; kw...)
pprint(io::GarishIO, x) = pprint(io, MIME"text/plain"(), x)

"""
    pprint(io::IO, mime::MIME, x; kw...)

Pretty print an object x with given `MIME` type.

!!! warning

    currently only supports `MIME"text/plain"`, the implementation
    of `MIME"text/html"` is coming soon. Please also feel free to
    file an issue if you have a desired format wants to support.
"""
function pprint(io::IO, mime::MIME, x; kw...)
    # NOTE: color is true by default since it's pprint already
    pprint(GarishIO(io; color=get(io, :color, true), kw...), mime, x)
end

function pprint(io::GarishIO, mime::MIME, @nospecialize(x))
    if fallback_to_default_show(io, x) && isstructtype(typeof(x))
        return pprint_struct(io, mime, x)
    elseif io.state.level > 0 # print show inside
        show_text_within(io, mime, x)
    else # fallback to show unless it is a struct type
        show(wrap_io_context(io), mime, x)
    end
end

function show_text_within(io::GarishIO, mime::MIME, x)
    buf = IOBuffer()
    indentation = io.indent * io.state.level + io.state.offset
    new_displaysize = (io.displaysize[1], io.displaysize[2] - indentation)
    buf_io = IOContext(IOContext(buf, wrap_io_context(io)), :limit=>true, :displaysize=>new_displaysize)
    show(buf_io, mime, x)
    raw = String(take!(buf))
    for (k, line) in enumerate(split(raw, '\n'))
        if !(io.state.noindent_in_first_line && k == 1)
            print_indent(io)
        end
        println(io.bland_io, line)
    end
    print_indent(io) # force put a new line at the end
    return
end

function pprint(io::GarishIO, mime::MIME, @specialize(x::Type))
    show(wrap_io_context(io), mime, x)
end

function pprint(io::GarishIO, mime::MIME"text/plain", @specialize(x::Type))
    print_token(io, :type, x)
end

"""
    print_indent(io::GarishIO)

Print an indentation. This should be only used under `MIME"text/plain"` or equivalent.
"""
function print_indent(io::GarishIO)
    io.compact && return
    io.state.level > 0 || return

    io.show_indent || return print(io, " "^(io.indent * io.state.level))
    for _ in 1:io.state.level
        print_token(io, :comment, "│")
        print(io, " "^(io.indent - 1))
    end
end

"""
    print_operator(io::GarishIO, op)

Print an operator, such as `=`, `+`, `=>` etc. This should be only used under `MIME"text/plain"` or equivalent.
"""
function print_operator(io::GarishIO, op)
    io.compact || print(io, " ")
    print_token(io, :operator, op)
    io.compact || print(io, " ")
end

function max_indent_reached(io::GarishIO, offset::Int)
    io.indent * io.state.level + io.state.offset + offset > io.displaysize[2]
end

function fallback_to_default_show(io::IO, x)
    # NOTE: Base.show(::IO, ::MIME"text/plain", ::Any) forwards to
    # Base.show(::IO, ::Any)

    # check if we are gonna call Base.show(::IO, ::MIME"text/plain", ::Any)
    mt = methods(Base.show, (typeof(io), MIME"text/plain", typeof(x)))
    length(mt.ms) == 1 && any(mt.ms) do method
        method.sig == Tuple{typeof(Base.show), IO, MIME"text/plain", Any}
    end || return false

    # check if we are gonna call Base.show(::IO, ::Any)
    mt = methods(Base.show, (typeof(io), typeof(x)))
    length(mt.ms) == 1 && return any(mt.ms) do method
        method.sig == Tuple{typeof(Base.show), IO, Any}
    end
end


include("struct.jl")
include("numbers.jl")
include("arrays.jl")
include("dict.jl")
include("set.jl")
include("misc.jl")

end
