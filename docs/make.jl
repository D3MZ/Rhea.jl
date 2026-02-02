using Persephone
using Documenter

DocMeta.setdocmeta!(Persephone, :DocTestSetup, :(using Persephone); recursive=true)

makedocs(;
    modules=[Persephone],
    authors="Demetrius Michael <arrrwalktheplank@gmail.com>",
    sitename="Persephone.jl",
    format=Documenter.HTML(;
        canonical="https://D3MZ.github.io/Persephone.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/D3MZ/Persephone.jl",
    devbranch="main",
)
