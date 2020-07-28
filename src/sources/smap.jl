using .HDF5

export SMAPstack, SMAPseries, SMAPmetadata, SMAPdimMetadata

const SMAPMISSING = -9999.0
const SMAPGEODATA = "Geophysical_Data"
const SMAPCRS = ProjString("+proj=cea +lon_0=0 +lat_ts=30 +x_0=0 +y_0=0 +datum=WGS84 +units=m +no_defs +ellps=WGS84 +towgs84=0,0,0")

"""
[`ArrayMetadata`](@ref) wrapper for `GDALarray`.
"""
struct SMAPmetadata{K,V} <: ArrayMetadata{K,V}
    val::Dict{K,V}
end

"""
[`DimMetadata`](@ref) wrapper for `SMAPstack` dimensions.
"""
struct SMAPdimMetadata{K,V} <: DimMetadata{K,V}
    val::Dict{K,V}
end

# Stack ########################################################################

"""
    SMAPstack(filename::String; window=())

`AbstractGeoStack` for [SMAP](https://smap.jpl.nasa.gov/) datasets.

The simplicity of the format means dims and refdims are the same for all stack layers,
so we store them as stack fields. `SMAPstack` should also serve as an example of defining
a custom source for HDF5 backed geospatial data.

# Keyword arguments
- `window`: can be a tuple of Dimensions, selectors or regular indices.
"""
struct SMAPstack{T,D,R,W,M} <: DiskGeoStack{T}
    filename::T
    dims::D
    refdims::R
    window::W
    metadata::M
end
SMAPstack(filename::String;
          dims=smapread(smapdims, filename),
          refdims=(smap_timedim(smap_timefrompath(filename)),),
          window=(),
          metadata=smapread(smapmetadata, filename),
         ) =
    SMAPstack(filename, dims, refdims, window, metadata)

# AbstractGeoStack methods

struct SMAParray end

# SMAP has fixed dims for all layers, so we store them on the stack.
dims(stack::SMAPstack, key::Key...) = stack.dims
dims(stack::SMAPstack, dim) = dims(dims(stack), dim)
refdims(stack::SMAPstack) = stack.refdims
metadata(stack::SMAPstack) = stack.metadata
missingval(stack::SMAPstack, key::Key...) = SMAPMISSING
childtype(stack::SMAPstack) = SMAParray
kwargs(stack::SMAPstack) = ()

withsource(f, ::Type{SMAParray}, path::AbstractString, key...) =
    smapread(f, path)
withsourcedata(f, ::Type{SMAParray}, path::AbstractString, key) =
    smapread(path) do d
        f(d[smappath(string(key))])
    end


# Base methods

# Override getindex as we already have `dims` - they are
# fixed for the whole stack
Base.getindex(s::SMAPstack, key::Key, i1::Integer, I::Integer...) =
    smapread(filename(s)) do file
        dataset = file[smappath(key)]
        _window = maybewindow2indices(dataset, _dims, window(s))
        readwindowed(dataset, _window, I...)
    end
Base.getindex(s::SMAPstack, key::Key, I::Union{Colon,Integer,AbstractArray}...) =
    smapread(filename(s)) do file
        dataset = file[smappath(key)]
        _dims = dims(s)
        _window = maybewindow2indices(dataset, _dims, window(s))
        _dims, _refdims = slicedims(slicedims(_dims, refdims(s), _window)..., I)
        A = readwindowed(dataset, _window, I...)
        GeoArray(A, _dims, _refdims, string(key), metadata(s), missingval(s))
    end

# HDF5 uses `names` instead of `keys` so we have to special-case it
Base.keys(stack::SMAPstack) =
    smapread(filename(stack)) do dataset
        cleankeys(names(dataset[SMAPGEODATA]))
    end


# Series #######################################################################

"""
    SMAPseries(path; kwargs...)

Series loader for SMAP folders (files in the time dimension).
Returns a [`GeoSeries`](@ref).

`path` can be a `String` path to a directory of SMAP files,
or a vector of `String` paths for specific files.
`kwargs` are passed to the constructor for `GeoSeries`.
"""
SMAPseries(path::AbstractString; kwargs...) =
    SMAPseries(joinpath.(path, filter_ext(path, ".h5")); kwargs...)
SMAPseries(filepaths::Vector{<:AbstractString}, dims=nothing; kwargs...) = begin
    if dims isa Nothing
        usedpaths = String[]
        timeseries = []
        errors = []
        for path in filepaths
            println(path)
            try
                t = smap_timefrompath(path)
                push!(timeseries, t)
                push!(usedpaths, path)
            catch e
                push!(errors, e)
            end
        end
        # Use the first files time dim as a template, but join vals into an array of times.
        timedim = smap_timedim(timeseries)
    else
        usedpaths = filepaths
    end
    if length(errors) > 0
        println("Some errors thrown during file load: ")
        println.(errors)
    end
    GeoSeries(usedpaths, (timedim,); childtype=SMAPstack, kwargs...)
end

Base.:*(hrs::Int, ::Type{T}) where T<:Period = T(hrs)

# Utils ########################################################################

smapread(f, filepath::AbstractString) = h5open(f, filepath)

readwindowed(A::HDF5Dataset, window::Tuple{}) = HDF5.read(A)

smappath(key::Key) = SMAPGEODATA * "/" * string(key)

smap_timefrompath(path::String) = begin
    dateformat = DateFormat("yyyymmddTHHMMSS")
    dateregex = r"SMAP_L4_SM_gph_(\d+T\d+)_"
    datematch = match(dateregex, path)
    if !(datematch === nothing)
        DateTime(datematch.captures[1], dateformat)
    else
        error("Date/time not correctly formatted in path: $path")
    end
end

smap_timedim(t::DateTime) = smap_timedim(t:Hour(3):t)
smap_timedim(times::AbstractVector) = 
    Ti(times, mode=Sampled(Ordered(), Regular(Hour(3)), Intervals(Start())))

smapmetadata(dataset::HDF5.HDF5File) = SMAPmetadata(Dict())

smapdims(dataset::HDF5.HDF5File) = begin
    proj = read(attrs(root(dataset)["EASE2_global_projection"]), "grid_mapping_name")
    if proj == "lambert_cylindrical_equal_area"
        # There are matrices for lookup but all rows/colums are identical.
        # For performance and simplicity we just take a vector slice for each dim.
        extent = attrs(root(dataset)["Metadata/Extent"])
        lonbounds = extent["westBoundLongitude"], extent["eastBoundLongitude"]
        latbounds = extent["northBoundLatitude"], extent["southBoundLatitude"]
        latvec = read(root(dataset)["cell_lat"])[1, :]
        lonvec = read(root(dataset)["cell_lon"])[:, 1]
        lonmode = Converted(Ordered(), Irregular(lonbounds),
                            Intervals(Center()), SMAPCRS, EPSG(4326))
        latmode = Converted(Ordered(Reverse(), Reverse(), Forward()), Irregular(latbounds),
                            Intervals(Center()), SMAPCRS, EPSG(4326))
        (Lon(lonvec; mode=lonmode), Lat(latvec; mode=latmode))
    else
        error("projection $proj not supported")
    end
end
