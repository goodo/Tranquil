#import "TQProgram.h"
#import "TQProgram+Internal.h"
#import "TQParse.h"
#import "TQNode.h"
#import "TQNodeVariable.h"
#import "TQNodeCustom.h"
#import "Processors/TQProcessor.h"
#import "ObjcSupport/TQHeaderParser.h"
#import "../Runtime/TQRuntime.h"
#import "../Runtime/TQBoxedObject.h"
#import "../Shared/TQDebug.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <llvm/Transforms/IPO/PassManagerBuilder.h>
#import <llvm/Target/TargetData.h>
#import <mach/mach_time.h>

#ifdef TQ_PROFILE
#import <google/profiler.h>
#endif

#include <llvm/Module.h>
#include <llvm/DerivedTypes.h>
#include <llvm/Constants.h>
#include <llvm/CallingConv.h>
#include <llvm/Instructions.h>
#include <llvm/PassManager.h>
#include <llvm/Analysis/Verifier.h>
#include <llvm/Target/TargetData.h>
#include <llvm/Target/TargetData.h>
#include <llvm/Target/TargetMachine.h>
#include <llvm/Target/TargetOptions.h>
#include <llvm/Transforms/Scalar.h>
#include <llvm/Transforms/IPO.h>
#include <llvm/Support/raw_ostream.h>
#if !defined(LLVM_TOT)
# include <llvm/Support/system_error.h>
#endif
#include <llvm/Support/PrettyStackTrace.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Intrinsics.h>
#include <llvm/Bitcode/ReaderWriter.h>
#include <llvm/LLVMContext.h>
#include <llvm/Support/ToolOutputFile.h>
#include <llvm/Support/TargetRegistry.h>
#include <llvm/Support/Host.h>
#include "llvm/ADT/Statistic.h"

using namespace llvm;

NSString * const kTQSyntaxErrorException = @"TQSyntaxErrorException";

static TQProgram *sharedInstance;

@implementation TQProgram
@synthesize name=_name, llModule=_llModule, shouldShowDebugInfo=_shouldShowDebugInfo,
            objcParser=_objcParser, searchPaths=_searchPaths, allowedFileExtensions=_allowedFileExtensions,
            useAOTCompilation=_useAOTCompilation, outputPath=_outputPath, arguments=_arguments, globals=_globals,
            evaluatedPaths=_evaluatedPaths;
@synthesize globalQueue=_globalQueue, debugBuilder=_debugBuilder;

+ (void)initialize
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] initWithName:@"Global"];
    });
}

+ (TQProgram *)sharedProgram
{
    return sharedInstance;
}

+ (TQProgram *)programWithName:(NSString *)aName
{
    return [[[self alloc] initWithName:aName] autorelease];
}

- (id)initWithName:(NSString *)aName
{
    if(!(self = [super init]))
        return nil;

    _name = [aName retain];
    _objcParser = [TQHeaderParser new];
    _llModule = new Module([_name UTF8String], getGlobalContext());
    llvm::LLVMContext &ctx = _llModule->getContext();

    _debugBuilder = new DIBuilder(*_llModule);

    TQInitializeRuntime(0, NULL);

    InitializeNativeTarget();
    LLVMInitializeX86Target();
    LLVMInitializeARMTargetMC();
    LLVMInitializeARMTargetInfo();
    LLVMInitializeARMTarget();

    _globals     = [NSMutableDictionary new];
    _searchPaths = [[NSMutableArray alloc] initWithObjects:@".",
                        @"~/Library/Frameworks", @"/Library/Frameworks",
                        @"/System/Library/Frameworks/", @"/usr/include/", @"/usr/local/include/",
                        @"/usr/local/tranquil/llvm/include", nil];
    _allowedFileExtensions = [[NSMutableArray alloc] initWithObjects:@"tq", @"h", nil];

    return self;
}

- (void)dealloc
{
    [_searchPaths release];
    [_globals release];
    [_allowedFileExtensions release];
    [_objcParser release];
    delete _llModule;
    [_arguments release];
    [super dealloc];
}

#pragma mark - Execution

// Prepares & optimizes the program tree before execution
- (void)_preprocessNode:(TQNode *)aNodeToIterate withTrace:(NSMutableArray *)aTrace
{
    if(!aNodeToIterate)
        return;
    [aTrace addObject:aNodeToIterate];
    [aNodeToIterate iterateChildNodes:^(TQNode *node) {
        for(Class processor in [TQProcessor allProcessors]) {
            [processor processNode:node withTrace:aTrace];
        }
        [self _preprocessNode:node withTrace:aTrace];
   }];
   [aTrace removeLastObject];
}

- (id)_executeRoot:(TQNodeRootBlock *)aNode error:(NSError **)aoErr
{
    if(!aNode)
        return nil;

    BOOL shouldResetEvalPaths = !_evaluatedPaths;
    if(shouldResetEvalPaths)
        _evaluatedPaths = [NSMutableArray array];

    GlobalVariable *argGlobal = NULL;
    Type *byRefType = [TQNodeVariable captureStructTypeInProgram:self];
    if(!_useAOTCompilation) {
        TQNodeVariable *varArgVar = [TQNodeVariable nodeWithName:@"TQArguments"];
        if([aNode referencesNode:varArgVar]) {
            // Create a global for the argument array
            argGlobal = new GlobalVariable(*_llModule, byRefType, false, GlobalVariable::InternalLinkage,
                                           ConstantAggregateZero::get(byRefType), "TQGlobalVar_TQArguments");
            _argGlobalForJIT.isa        = nil;
            _argGlobalForJIT.flags      = 0;
            _argGlobalForJIT.size       = sizeof(TQBlockByRef);
            _argGlobalForJIT.value      = nil;
            _argGlobalForJIT.value      = _arguments;
            _argGlobalForJIT.forwarding = &_argGlobalForJIT;
            // Insert a reference to the '...' variable so that child blocks know to capture it
            [aNode.statements insertObject:varArgVar atIndex:0];
        }

        // Global for the dispatch queue
        _globalQueue = _llModule->getNamedGlobal("TQGlobalQueue");
        if(!_globalQueue)
            _globalQueue = new GlobalVariable(*_llModule, self.llInt8PtrTy, false, GlobalVariable::ExternalLinkage,
                                              NULL, "TQGlobalQueue");
    } else {
        if(!_llModule->getNamedGlobal("TQGlobalVar_TQArguments"))
            new GlobalVariable(*_llModule, byRefType, false, GlobalVariable::ExternalLinkage, NULL, "TQGlobalVar_TQArguments");
        TQNodeVariable *cliArgGlobal = [TQNodeVariable globalWithName:@"TQArguments"];
        [_globals setObject:cliArgGlobal forKey:@"TQArguments"];

        _globalQueue = _llModule->getNamedGlobal("TQGlobalQueue");
        if(!_globalQueue)
            _globalQueue = new GlobalVariable(*_llModule, self.llInt8PtrTy, false, GlobalVariable::ExternalLinkage, NULL, "TQGlobalQueue");
    }

    NSError *err = nil;
    [aNode generateCodeInProgram:self block:nil root:aNode error:&err];
    if(err) {
        TQLog(@"Error: %@", err);
        if(shouldResetEvalPaths)
            _evaluatedPaths = nil;
        return NO;
    }

    if(_shouldShowDebugInfo) {
        llvm::EnableStatistics();
        _llModule->dump();
        // Verify that the program is valid
        verifyModule(*_llModule, PrintMessageAction);
    }

    // Compile program
    TargetOptions Opts;
    Opts.JITEmitDebugInfo = true;
    Opts.JITExceptionHandling = true;
    Opts.JITEmitDebugInfoToDisk = true;
    Opts.GuaranteedTailCallOpt = true;
    Opts.NoFramePointerElim = true;

    PassRegistry &Registry = *PassRegistry::getPassRegistry();
    initializeCore(Registry);
    initializeScalarOpts(Registry);
    initializeVectorization(Registry);
    initializeIPO(Registry);
    initializeAnalysis(Registry);
    initializeIPA(Registry);
    initializeTransformUtils(Registry);
    initializeInstCombine(Registry);
    initializeInstrumentation(Registry);
    initializeTarget(Registry);

    PassManager modulePasses;

    FunctionPassManager fpm = FunctionPassManager(_llModule);

    if(!_useAOTCompilation) {
        if(!_executionEngine) {
            EngineBuilder factory(_llModule);
            factory.setEngineKind(llvm::EngineKind::JIT);
            factory.setTargetOptions(Opts);
            factory.setOptLevel(CodeGenOpt::Aggressive);
            factory.setUseMCJIT(true);
            factory.setRelocationModel(Reloc::PIC_);
            _executionEngine = factory.create();
            //_executionEngine->DisableLazyCompilation();
            fpm.add(new TargetData(*_executionEngine->getTargetData()));
        }
        if(argGlobal)
            _executionEngine->addGlobalMapping(argGlobal, (void*)&_argGlobalForJIT);
        if(!_globalQueueForJIT)
            _globalQueueForJIT = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
        _executionEngine->addGlobalMapping(_globalQueue, (void*)&_globalQueueForJIT);
    }

    // Optimization pass
    PassManagerBuilder builder = PassManagerBuilder();
    builder.OptLevel = 3;
    PassManagerBuilder Builder;
    builder.Inliner = createFunctionInliningPass();
    builder.populateFunctionPassManager(fpm);
    builder.populateModulePassManager(modulePasses);

    fpm.add(createInstructionCombiningPass());
    // Eliminate unnecessary alloca.
    fpm.add(createPromoteMemoryToRegisterPass());
    // Reassociate expressions.
    fpm.add(createReassociatePass());
    // Eliminate Common SubExpressions.
    fpm.add(createGVNPass());
    // Simplify the control flow graph (deleting unreachable blocks, etc).
    fpm.add(createCFGSimplificationPass());
    // Eliminate tail calls.
    fpm.add(createTailCallEliminationPass());

   if(_useAOTCompilation) {
        // Output
        Opts.JITEmitDebugInfo = false;
        std::string err;
        std::string targetTriple, featureStr, cpuName;
        cpuName = "";
        switch(_targetArch) {
            case kTQArchitectureHost:
                targetTriple = sys::getDefaultTargetTriple();
                cpuName      = sys::getHostCPUName();
                break;
            case kTQArchitectureI386:
                targetTriple = "i386-apple-darwin11.0.0";
                break;
            case kTQArchitectureX86_64:
                targetTriple = "x86_64-apple-darwin11.0.0";
                break;
            case kTQArchitectureARMv7:
                targetTriple = "arm-apple-darwin11.0.0";
        }
        //for(TargetRegistry::iterator it = TargetRegistry::begin(), ie = TargetRegistry::end(); it != ie; ++it) {
        //    NSLog(@"target: %s", it->getName());
        //}

        const Target *target = TargetRegistry::lookupTarget(targetTriple, err);
        TQAssert(err.empty(), @"Unable to get target data: %s", err.c_str());

        TargetMachine *machine = target->createTargetMachine(targetTriple, cpuName, "", Opts);
        TQAssert(machine, @"Unable to create llvm target machine");
        modulePasses.add(new TargetData(*(machine->getTargetData())));
        modulePasses.run(*_llModule);
        fpm.run(*aNode.function);

        verifyModule(*_llModule, PrintMessageAction);
        if(_shouldShowDebugInfo) {
            _llModule->dump();
            llvm::PrintStatistics();
        }

        raw_fd_ostream out([_outputPath UTF8String], err, raw_fd_ostream::F_Binary);
        TQAssert(err.empty(), @"Error opening output file for bitcode: %@", _outputPath);
        WriteBitcodeToFile(_llModule, out);
        out.close();
        exit(0);
    }

    if(!_shouldShowDebugInfo) {
        fpm.run(*aNode.function);
        modulePasses.run(*_llModule);
    }

    if(_shouldShowDebugInfo) {
        //_llModule->dump();
        llvm::PrintStatistics();
        fprintf(stderr, "---------------------\n");
    }

    id(*rootPtr)() = (id(*)())_executionEngine->getPointerToFunction(aNode.function);

    uint64_t startTime = mach_absolute_time();
    // Execute code
#ifdef TQ_PROFILE
    ProfilerStart("tqprof.txt");
#endif
    id ret = nil;
    @try {
        ret = rootPtr();
    } @catch (NSException *e) {
        if(aoErr) *aoErr = [NSError errorWithDomain:kTQRuntimeErrorDomain
                                               code:kTQObjCException
                                           userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[e reason], @"reason",
                                                                                               e, @"exception", nil]];
    }
#ifdef TQ_PROFILE
    ProfilerStop();
#endif

    if(shouldResetEvalPaths)
        _evaluatedPaths = nil;

    uint64_t ns = mach_absolute_time() - startTime;
    struct mach_timebase_info timebase;
    mach_timebase_info(&timebase);
    double sec = ns * timebase.numer / timebase.denom / 1000000000.0;

    if(_shouldShowDebugInfo) {
        fprintf(stderr, "---------------------\n");
        TQLog(@"Run time: %f sec. Ret: %p", sec, ret);
        TQLog(@"'root' retval:  %p: %@ (%@)", ret, ret ? ret : nil, [ret class]);
    }

    return ret;
}

- (TQNodeRootBlock *)_rootFromFile:(NSString *)aPath error:(NSError **)aoErr
{
    NSString *script = [NSString stringWithContentsOfFile:aPath usedEncoding:NULL error:nil];
    if(!script)
        TQAssert(NO, @"Unable to load script from %@", aPath);
    return [self _parseScript:script error:aoErr];
}
- (id)executeScriptAtPath:(NSString *)aPath error:(NSError **)aoErr
{
    TQNodeRootBlock *root = [self _rootFromFile:aPath error:aoErr];
    if(!root)
        return nil;
    return [self _executeRoot:root error:aoErr];
}
- (id)executeScriptAtPath:(NSString *)aPath onError:(TQErrorHandlingBlock)aHandler;
{
    NSError *err = nil;
    id result = [self executeScriptAtPath:aPath error:&err];
    if(err) {
        if(aHandler) aHandler(err);
        return nil;
    }
    return result;
}

- (TQNodeRootBlock *)_parseScript:(NSString *)aScript error:(NSError **)aoErr
{
    // Remove shebang
    if([aScript hasPrefix:@"#!"]) {
        // TODO Make this handle multibytes
        int lineEnd = 0;
        const char *cStr = [aScript UTF8String];
        for(lineEnd = 0; lineEnd < [aScript length] && cStr[lineEnd] != '\n'; ++lineEnd);
        aScript = [aScript substringFromIndex:lineEnd];
    }

    TQNodeRootBlock *root = TQParseString(aScript, aoErr);
    if(!root)
        return nil;

    // Initialize the debug unit on the root
    const char *filename = "<none>";
    const char *dir      = "<none>";
    _debugBuilder->createCompileUnit(dwarf::DW_LANG_ObjC, filename, dir, TRANQUIL_DEBUG_DESCR, true, "", 1); // Use DW_LANG_Tranquil ?
    root.debugUnit = DICompileUnit(_debugBuilder->getCU());

    [self _preprocessNode:root withTrace:[NSMutableArray array]];
    if(_shouldShowDebugInfo)
        TQLog(@"%@", root);
    return root;
}

- (id)executeScript:(NSString *)aScript error:(NSError **)aoErr
{
    TQNodeRootBlock *root = [self _parseScript:aScript error:aoErr];
    if(!root)
        return nil;
    return [self _executeRoot:root error:aoErr];
}

- (id)executeScript:(NSString *)aScript onError:(TQErrorHandlingBlock)aHandler
{
    NSError *err = nil;
    id result = [self executeScript:aScript error:&err];
    if(err) {
        if(aHandler) aHandler(err);
        return nil;
    }
    return result;
}

#pragma mark - Utilities

- (NSString *)_resolveImportPath:(NSString *)aPath
{
#define NOT_FOUND() do { TQLog(@"No file found for path '%@'", aPath); return nil; } while(0)
    BOOL isDir;
    NSFileManager *fm = [NSFileManager defaultManager];
    if([aPath hasPrefix:@"/"]) {
        if([fm fileExistsAtPath:aPath isDirectory:&isDir] && !isDir)
            return aPath;
        NOT_FOUND();
    }
    NSArray *testPathComponents = [aPath pathComponents];
    if(![testPathComponents count])
        NOT_FOUND();

    BOOL hasExtension = [[aPath pathExtension] length] > 0;
    BOOL usesSubdir   = [testPathComponents count] > 1;

    for(NSString *searchPath in _searchPaths) {
        if(![fm fileExistsAtPath:searchPath isDirectory:&isDir] || !isDir)
            continue;

        for(NSString *candidate in [fm contentsOfDirectoryAtPath:searchPath error:nil]) {
            if([[candidate pathExtension] isEqualToString:@"framework"]) {
                NSString *frameworkDirName = usesSubdir ? [testPathComponents objectAtIndex:0] : [[aPath lastPathComponent] stringByDeletingPathExtension];
                if(![[[candidate lastPathComponent] stringByDeletingPathExtension] isEqualToString:frameworkDirName])
                    continue;
                if(usesSubdir)
                    aPath = [[testPathComponents subarrayWithRange:(NSRange){ 1, [testPathComponents count] - 1 }] componentsJoinedByString:@"/"];
                searchPath = [[searchPath stringByAppendingPathComponent:candidate] stringByAppendingPathComponent:@"Headers"];
                break;
            }
        }
        NSString *finalPath = [searchPath stringByAppendingPathComponent:aPath];
        if(hasExtension) {
            if([fm fileExistsAtPath:finalPath isDirectory:&isDir] && !isDir)
                return finalPath;
        } else {
            for(NSString *ext in _allowedFileExtensions) {
                NSString *currPath = [finalPath stringByAppendingPathExtension:ext];
                if([fm fileExistsAtPath:currPath isDirectory:&isDir] && !isDir)
                    return currPath;
            }
        }
    }

    NOT_FOUND();
#undef NOT_FOUND
}

- (llvm::Value *)getGlobalStringPtr:(NSString *)aStr withBuilder:(llvm::IRBuilder<> *)aBuilder
{
    NSString *globalName;
    // When compiling AOT certain symbols in the global name can cause llvm to generate invalid ASM => we use the hash in that case (which destroys the output's readbility)
    if(_useAOTCompilation)
        globalName = [NSString stringWithFormat:@"TQConstCStr_%ld", [aStr hash]];
    else
        globalName = [NSString stringWithFormat:@"TQConstCStr_%@", aStr];

    GlobalVariable *global = _llModule->getGlobalVariable([globalName UTF8String], true);
    if(!global) {
        Constant *strConst = ConstantDataArray::getString(_llModule->getContext(), [aStr UTF8String]);
        global = new GlobalVariable(*_llModule, strConst->getType(),
                                    true, GlobalValue::PrivateLinkage,
                                    strConst, [globalName UTF8String]);
    }

    Value *zero = ConstantInt::get(Type::getInt32Ty(_llModule->getContext()), 0);
    Value *indices[] = { zero, zero };
    return aBuilder->CreateInBoundsGEP(global, indices);
}

- (llvm::Value *)getGlobalStringPtr:(NSString *)aStr inBlock:(TQNodeBlock *)aBlock
{
    return [self getGlobalStringPtr:aStr withBuilder:aBlock.builder];
}

- (void)insertLogUsingBuilder:(llvm::IRBuilder<> *)aBuilder withStr:(NSString *)txt
{
    std::vector<Type*> nslog_args;
    nslog_args.push_back(self.llInt8PtrTy);
    FunctionType *printf_type = FunctionType::get(self.llIntTy, nslog_args, true);
    Function *func_printf = _llModule->getFunction("printf");
    if(!func_printf) {
        func_printf = Function::Create(printf_type, GlobalValue::ExternalLinkage, "printf", _llModule);
        func_printf->setCallingConv(CallingConv::C);
    }
    std::vector<Value*> args;
    args.push_back([self getGlobalStringPtr:@"> %s\n" withBuilder:aBuilder]);
    args.push_back([self getGlobalStringPtr:txt withBuilder:aBuilder]);
    aBuilder->CreateCall(func_printf, args);
}

@end
