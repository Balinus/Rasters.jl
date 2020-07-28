using GeoData, Test
using GeoData: cleankeys, shiftindexloci

@testset "cleankeys" begin
    @test cleankeys(["a", "b", "c"]) == (:a, :b, :c)
    @test cleankeys(("a", "b", "c")) == (:a, :b, :c)
end

@testset "shiftindexloci" begin
    dim = X(1.0:3.0; mode=Sampled(Ordered(), Regular(1.0), Intervals(Center())))
    @test shiftindexloci(Start(), dim) == 0.5:1.0:2.5
    @test shiftindexloci(End(), dim) == 1.5:1.0:3.5
    @test shiftindexloci(Center(), dim) == 1.0:1.0:3.0
    dim = X([3, 4, 5]; mode=Sampled(Ordered(), Regular(1), Intervals(Start())))
    @test shiftindexloci(End(), dim) == [4, 5, 6]
    @test shiftindexloci(Center(), dim) == [3.5, 4.5, 5.5]
    @test shiftindexloci(Start(), dim) == [3, 4, 5]
    dim = X([3, 4, 5]; mode=Sampled(Ordered(), Regular(1), Intervals(End())))
    @test shiftindexloci(End(), dim) == [3, 4, 5]
    @test shiftindexloci(Center(), dim) == [2.5, 3.5, 4.5]
    @test shiftindexloci(Start(), dim) == [2, 3, 4]
end
