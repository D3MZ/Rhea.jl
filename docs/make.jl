using Rhea
using Documenter

DocMeta.setdocmeta!(Rhea, :DocTestSetup, :(using Rhea); recursive=true)

makedocs(;
    modules=[Rhea],
    authors="Demetrius Michael <arrrwalktheplank@gmail.com>",
    sitename="Rhea.jl",
    format=Documenter.HTML(;
        canonical="https://D3MZ.github.io/Rhea.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/D3MZ/Rhea.jl",
    devbranch="main",
)
