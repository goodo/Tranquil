#import "TQNodeDictionary.h"
#import "../TQProgram.h"
#import "TQNodeBlock.h"
#import "TQNodeArgument.h"
#import "TQNodeVariable.h"
#import "TQNodeNil.h"

using namespace llvm;

@implementation TQNodeDictionary
@synthesize items=_items;

+ (TQNodeDictionary *)node
{
    return (TQNodeDictionary *)[super node];
}

- (void)dealloc
{
    [_items release];
    [super dealloc];
}

- (NSString *)description
{
    NSMutableString *out = [NSMutableString stringWithString:@"<dict@["];

    for(TQNode *key in _items) {
        [out appendFormat:@"%@ => %@, ", key, [_items objectForKey:key]];
    }

    [out appendString:@"]>"];
    return out;
}

- (TQNode *)referencesNode:(TQNode *)aNode
{
    TQNode *ref = nil;

    if([self isEqual:aNode])
        return self;
	NSEnumerator *keyEnum = [_items keyEnumerator];
	TQNode *key;
	while(key = [keyEnum nextObject]) {
		if((ref = [key referencesNode:aNode]))
			return ref;
		else if((ref = [[_items objectForKey:key] referencesNode:aNode]))
			return ref;
	}

    return nil;
}

- (llvm::Value *)generateCodeInProgram:(TQProgram *)aProgram block:(TQNodeBlock *)aBlock error:(NSError **)aoErr
{
    IRBuilder<> *builder = aBlock.builder;
    Module *mod = aProgram.llModule;

    std::vector<Value *>args;
    args.push_back(mod->getOrInsertGlobal("OBJC_CLASS_$_NSMapTable", aProgram.llInt8Ty));
    args.push_back(builder->CreateLoad(mod->getOrInsertGlobal("TQMapWithObjectsAndKeysSel", aProgram.llInt8PtrTy)));
    TQNode *value;

    int count = 0;
    for(TQNode *key in _items) {
        ++count;
        assert(![key isKindOfClass:[TQNodeNil class]]);
        value = [_items objectForKey:key];
        args.push_back([value generateCodeInProgram:aProgram block:aBlock error:aoErr]);
        if(*aoErr) return NULL;
        args.push_back([key generateCodeInProgram:aProgram block:aBlock error:aoErr]);
        if(*aoErr) return NULL;
    }
    assert(count%2 == 0);
    args.push_back(builder->CreateLoad(mod->getOrInsertGlobal("TQSentinel", aProgram.llInt8PtrTy)));

    CallInst *call = builder->CreateCall(aProgram.objc_msgSend, args);
    return call;
}

@end
