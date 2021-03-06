#import <Tranquil/CodeGen/TQNode.h>
#import "TQNodeBlock.h"

@class TQNodeClass, TQNodeArgumentDef;

typedef enum {
    kTQClassMethod,
    kTQInstanceMethod
} TQMethodType;

// A method definition (+ aMethod: argument { body })
@interface TQNodeMethod : TQNodeBlock {
    TQNodeClass *_class;
}
@property(readwrite, assign) TQMethodType type;
+ (TQNodeMethod *)node;
+ (TQNodeMethod *)nodeWithType:(TQMethodType)aType;
- (NSString *)selector;
- (id)initWithType:(TQMethodType)aType;
- (BOOL)addArgument:(TQNodeArgumentDef *)aArgument error:(NSError **)aoErr;
- (llvm::Value *)generateCodeInProgram:(TQProgram *)aProgram
                                 block:(TQNodeBlock *)aBlock
                                 class:(TQNodeClass *)aClass
                                  root:(TQNodeRootBlock *)aRoot
                                 error:(NSError **)aoErr;
@end
