# Generates block dispatch stubs up to a specified maximum number of arguments

maxArgs = 32 # If you want functions that take more than 32 arguments, reconsider the reasons that made you start programming.

source = "// This file was autogenerated so don't modify it.
// (Compiled with support for up to #{maxArgs} arguments)

\#import <Tranquil/TQDebug.h>
\#import <Tranquil/Runtime/TQRuntime.h>
// Passing the sentinel represents that no argument was passed for that slot
\#define TQS TQSentinel

extern \"C\" {
"

(0..maxArgs).each do |i|
    source << "id TQDispatchBlock#{i}(struct TQBlockLiteral *block"; (1..i).each { |j| source << ", id a#{j}" }; source << ")
{
    static void *underflowJmpTbl[] = { "
    (i..maxArgs).each { |j| source << "&&underflow#{j-i}"; source << ", " unless j == maxArgs }; source << " };\n"
    source << "
    if(block->flags & TQ_BLOCK_IS_TRANQUIL_BLOCK) {
        if(block->descriptor->numArgs > #{maxArgs})
            TQAssert(NO, @\"Tranquil was compiled with support for #{maxArgs} block arguments. You tried to call a block that takes %d.\", block->descriptor->numArgs);
        else if(block->descriptor->isVariadic) {
            if(block->descriptor->numArgs <= #{i})
                goto *underflowJmpTbl[0];
            else
                goto *underflowJmpTbl[block->descriptor->numArgs"; source << " - #{i}" unless i == 0; source <<"];
        } else {
            if(block->descriptor->numArgs == #{i})
                return block->invoke(block"; (1..i).each { |j| source << ", a#{j}"; }; source << ");
            else if(block->descriptor->numArgs > #{i})
                goto *underflowJmpTbl[block->descriptor->numArgs"; source << "- #{i+1}" unless i == 0; source <<"];
            else if(block->descriptor->numArgs < #{i})
                TQAssert(NO, @\"Too many arguments to %@! #{i} for %d\", block, block->descriptor->numArgs);
        }
    } else // Foreign block -> no validation possible
        return block->invoke(block"; (1..i).each { |j| source << ", a#{j}"; }; source << ");

"
    (i..maxArgs).each do |j|
    source << "    underflow#{j-i}:\n"
    source << "        return block->invoke(block";
        (1..i).each { |k| source << ", a#{k}" };
        (i..j).each { |k| source << ", TQS"; }; source << ");\n"
    end
    source << "}\n\n"
end

source << "#undef TQS
}\n"
print source
