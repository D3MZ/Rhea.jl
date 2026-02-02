using Persephone, JSON
import Persephone: node_from_dict

d = JSON.parsefile("latest_population.json")
nodes = node_from_dict.(d)

# simple printer
function showexpr(n)
    if n isa ConstNode
        return string(round(n.val, digits=3))
    elseif n isa FeatureNode
        return string(n.feature, "(", n.param, ")")
    elseif n isa OpNode
        kids = showexpr.(n.children)
        if n.op == :IfGT
            return "if " * kids[1] * " > " * kids[2] * " then " * kids[3] * " else " * kids[4]
        else
            return "(" * kids[1] * " " * string(n.op) * " " * kids[2] * ")"
        end
    end
end

println(showexpr(nodes[1]))
