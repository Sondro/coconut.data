package coconut.data.macros;

#if !macro
  #error
#end

import haxe.macro.Context;
import haxe.macro.Expr;
using tink.MacroApi;
using tink.CoreApi;

private typedef FieldContext = {
  var name(default, null):String;
  var pos(default, null):Position;
  var type(default, null):ComplexType;
  var expr(default, null):Null<Expr>;
  var meta(default, null):MetadataEntry;
}

private enum Init {
  Skip;
  Value(e:Expr);
  Arg(?type:ComplexType);
  OptArg(defaultsTo:Expr, ?type:ComplexType);
}

private typedef Result = {
  var getter(default, null):Expr;
  @:optional var setter(default, null):Expr;
  @:optional var stateful(default, null):Bool;
  @:optional var transitionable(default, null):Bool;
  @:optional var type(default, null):ComplexType;
  var init(default, null):Init;
}

class ModelBuilder {

  var fieldDirectives:Array<Named<FieldContext->Result>>;

  var c:ClassBuilder;
  var isInterface:Bool;

  public function new(c) {

    //TODO: refactor this horrible piece of crap

    this.c = c;

    this.isInterface = c.target.isInterface;
    
    var OPTIONAL = [{ name: ':optional', params: [], pos: c.target.pos }];

    fieldDirectives = [
      new Named(':constant'  , constantField),
      new Named(':external'  , externalField),
      new Named(':computed'  , computedField.bind(_, false)),
      new Named(':loaded'    , computedField.bind(_, true)), 
      new Named(':editable'  , observableField.bind(_, true)),
      new Named(':observable', observableField.bind(_, false)),
    ];

    if (isInterface)
      fieldDirectives = fieldDirectives.filter(function (n) return n.name != ':loaded');
    else
      if (!c.target.meta.has(':tink'))
        c.target.meta.add(':tink', [], c.target.pos);
    
    var publishConstructor = true;
    var postConstruct = {
      var ctor:Member = null,
          a = @:privateAccess c.initializeFrom;

      for (f in a)
        if (f.name == 'new') {
          ctor = f;
          break;
        }

      if (ctor != null) {
        publishConstructor = ctor.isPublic;
        a.remove(ctor);
        var f = ctor.getFunction().sure();
        if (f.args.length > 0)
          ctor.pos.error('constructor must not have arguments');
        
        macro @:pos(f.expr.pos) tink.state.Observable.untracked(function () {
          ${f.expr};
          return tink.core.Noise.Noise;
        });
      }
      else macro {};
    }

    var argFields = [],
        transitionFields = [],
        observableFields = [],
        observableInit = [];

    var argType = TAnonymous(argFields),
        transitionType = TAnonymous(transitionFields),
        observables = TAnonymous(observableFields),
        observablesObj = EObjectDecl(observableInit).at();

    var cFunc = (macro function (?initial:$argType) {
    }).getFunction().sure();

    var constr = 
      if (!isInterface) {
        var c = c.getConstructor(cFunc);
        if (publishConstructor) c.publish();
        c;
      }
      else null;

    for (member in c) 
      if (!member.isStatic)
        switch member.kind {
          case FProp(_, _, _, _): 
          
            member.pos.error('Custom properties not allowed in models');

          case FVar(t, e):

            if (t == null) 
              member.pos.error('Field requires explicit type');
            
            var found = None;

            function addResult(res:Result, external:Bool) {
              var name = member.name;

              var finalType = switch res.type {
                case null: t;
                case v: v;
              }

              if (res.getter != null)
                c.addMember(Member.getter(name, res.getter, finalType));

              var setter = 
                switch res.setter {
                  case null:
                    'never';
                  case v:
                    c.addMember(Member.setter(name, v, finalType));
                    'set';
                }

              member.kind = FProp('get', setter, finalType, null);
              member.publish();

              function addArg(?meta, ?type)
                argFields.push({
                  name: name,
                  pos: member.pos,
                  meta: meta,
                  kind: FProp('default', 'null', if (type == null) t else type),
                });

              function getValue() 
                return switch res.init {
                  case Value(e): macro @:pos(e.pos) ($e : $t);
                  case Arg(type): 
                    cFunc.args[0].opt = false;
                    addArg(type);
                    macro initial.$name;

                  case OptArg(e, type):
                    
                    addArg(OPTIONAL, type);
                    macro switch initial.$name {
                      case null: @:pos(e.pos) ($e : $t);
                      case v: v;
                    }

                  case Skip: 
                    null;
                }

              if (res.stateful) {
                if (res.transitionable)
                  transitionFields.push({
                    name: name,
                    pos: member.pos,
                    kind: FProp('default', 'never', t),
                    meta: OPTIONAL,
                  });

                switch getValue() {
                  case null:
                    throw "assert";
                  case e: 
                    var state = stateOf(name);
                    var st = 
                      if (external)
                        macro : tink.state.Observable<$t> 
                      else {
                        e = macro @:pos(e.pos) new tink.state.State($e);
                        macro : tink.state.State<$t>;
                      }
                    add(macro class {
                      @:noCompletion private var $state:$st;
                    });
                    constr.init(state, e.pos, Value(e));
                }
              }
              else switch getValue() {
                case null:
                case v:
                  constr.init(name, member.pos, Value(v), { bypass: true });
              }  

              if (member.isPublic) {
                observableFields.push({
                  name: name,
                  pos: member.pos,
                  kind: FProp('default', 'never', macro : tink.state.Observable<$finalType>)
                });                

                observableInit.push({
                  field: name,
                  expr: 
                    switch stateOf(name) {
                      case obs if (c.hasMember(obs)): macro this.$obs;
                      default: macro tink.state.Observable.const(this.$name);
                    }
                });
              }
            }

            for (directive in fieldDirectives) 
              found = 
                switch [found, member.extractMeta(directive.name)] {
                  case [None, Success(m)]: Some({ apply: directive.value, meta: m });
                  case [Some({ meta: { name: previous } }), Success({ pos: pos, name: conflicting })]:
                    pos.error('Conflicting directives @:$previous and @:$conflicting');
                  case [v, _]: v;
                }

            if (!member.extractMeta(':skipCheck').isSuccess())
              switch Models.check(member.pos.getOutcome(t.toType())) {
                case []:
                case v: member.pos.error(v[0]);
              }

            switch found {
              case None: 
                if (isInterface) {
                  addResult({ 
                    init: Skip, 
                    getter: null, 
                    type: if (member.extractMeta(':loaded').isSuccess()) macro : tink.state.Promised<$t> else null,
                  }, false);
                }
                else
                  member.pos.error('Plain fields not allowed on models');
              case Some(v):

                if (isInterface)
                  v.meta.pos.error('Directives other than `@:loaded` not allowed on interface fields');

                addResult(v.apply({
                  name: member.name,
                  type: t,
                  expr: e,
                  pos: member.pos,
                  meta: v.meta,
                }), v.meta.name == ':external');

            }

            switch member.extractMeta(':transition') {
              case Success(m):
                m.pos.error('@:transition not allowed on fields');
              default:
            }
          default:
        }

    for (member in c) 
      if (!member.isStatic)
        switch member.kind {
          default:        
          case FFun(f):

            switch member.extractMeta(':transition') {
              case Success({ params: params, pos: pos }):
                if (transitionFields.length == 0)
                  pos.error('Cannot have transitions when there are no @:observable fields');
                member.publish();

                var ret = null;

                for (v in params)
                  switch v {
                    case macro return $e: 
                      if (ret == null)
                        ret = e;
                      else
                        v.reject('Only one return clause allowed');
                    default:
                      v.reject();
                  }

                if (ret == null)
                  ret = macro return (Noise:tink.core.Noise);

                var retType = transitionType;

                if (ret == null) 
                  ret = macro null;
                else
                  retType = (function () return ret.typeof().sure()).lazyComplex();

                function next(e:Expr) return switch e {
                  case macro @patch $v: macro @:pos(e.pos) ($v : $transitionType);
                  default: e.map(next);
                }

                f.expr = macro @:pos(f.expr.pos) coconut.data.macros.Models.transition(
                  function ():tink.core.Promise<$transitionType> ${next(f.expr)}, $ret
                );

                f.ret = macro : tink.core.Promise<$retType>;

              default:
            }

            for (d in fieldDirectives)
              switch member.extractMeta(d.name) {
                case Success({ pos: p, name: n }):
                  p.error('@:$n not allowed on functions');
                default:
              }
                
        }
    
    
    // transitionLink    
    observableFields.push({
      name: 'isInTransition',
      pos: Context.currentPos(),
      kind: FProp('default', 'never', macro : tink.state.Observable<Bool>)
    });
    
    observableInit.push({
      field: 'isInTransition',
      expr: macro this.__coco_transitionCount.observe().map(function(c) return c > 0),
    });
        
    if (isInterface) 
      add(macro class {
        var observables(default, never):$observables;
        var transitionErrors(default, never):tink.core.Signal<tink.core.Error>;
        public var isInTransition(get, never):Bool;
      });
    else {
      if (cFunc.args[0].opt)
        constr.addStatement(macro if(initial == null) initial = {}, true);
        
      constr.init('__coco_transitionCount', c.target.pos, Value(macro new tink.state.State(0)), {bypass: true});
      constr.init('errorTrigger', c.target.pos, Value(macro tink.core.Signal.trigger()), {bypass: true});
      constr.init('transitionErrors', c.target.pos, Value(macro errorTrigger), {bypass: true});
      constr.init('observables', c.target.pos, Value(macro ($observablesObj : $observables)), { bypass: true });
      constr.addStatement(postConstruct);
      var updates = [];
      
      for (f in transitionFields) {
        var name = f.name;
        updates.push(macro if (delta.$name != null) $i{stateOf(name)}.set(delta.$name));
      }
      var sparse = TAnonymous([for (f in transitionFields) {//this is a workaround for Haxe issue #6316 and also enables settings fields to null
        meta: OPTIONAL,
        name: f.name,
        pos: f.pos,
        kind: FVar(
          switch f.kind { 
            case FProp(_, _, t, _): macro : tink.core.Ref<$t>; 
            default: throw 'assert'; 
          }
        ),
      }]);

      add(macro class {
        @:noCompletion function __cocoupdate(delta:$transitionType) {
          var sparse = new haxe.DynamicAccess<tink.core.Ref<Any>>(),
              delta:haxe.DynamicAccess<Any> = cast delta;

          for (k in delta.keys())
            sparse[k] = tink.core.Ref.to(delta[k]);
          var delta:$sparse = cast sparse; 
          $b{updates};
        }
        public var observables(default, never):$observables;
        public var transitionErrors(default, never):tink.core.Signal<tink.core.Error>;
        var errorTrigger(default, never):tink.core.Signal.SignalTrigger<tink.core.Error>;
        var __coco_transitionCount(default, never):tink.state.State<Int>;
        public var isInTransition(get, never):Bool;
        inline function get_isInTransition() return observables.isInTransition.value;
      });

      c.target.meta.add(':final', [], c.target.pos);
    }
  }
  static public function stateOf(name:String)
    return '__coco_$name';

  function add(td:TypeDefinition)
    for (f in td.fields)
      c.addMember(f);  

  function externalField(ctx:FieldContext):Result {
    var state = stateOf(ctx.name),
        type = ctx.type;
    return {
      getter: macro this.$state.value,
      init: switch ctx.expr {
        case null: Arg(macro : coconut.data.Value<$type>);
        // case macro @byDefault $e: OptArg(e, macro : coconut.data.Value<$type>);
        case e: e.reject('@:external fields cannot be initialized. Consider using @:constant or @:computed instead');
      },
      type: type,
      stateful: true,      
    }
  }

  function constantField(ctx:FieldContext):Result {
    var name = ctx.name;
    
    return {
      getter: macro @:pos(ctx.pos) this.$name,
      init: switch ctx.expr {
        case null: Arg();
        case macro @byDefault $v: OptArg(v);
        case v: Value(v);
      },
    }
  }

  function computedField(ctx:FieldContext, async:Bool):Result {
    
    var state = stateOf(ctx.name),
        type = switch [async, ctx.type] {
          case [true, v]:
            macro : tink.state.Promised<$v>;
          case [_, v]: v;
        },
        comp = switch [async, ctx.type] {
          case [true, v]:
            macro : tink.core.Promise<$v>;
          case [_, v]: v;
        };

    c.getConstructor().init(
      state, 
      ctx.pos, 
      Value(macro @:pos(ctx.pos) tink.state.Observable.auto(
        (function ():$comp return ${ctx.expr}:tink.state.Observable.Computation<$type>)
      ))
    );

    add(macro class {
      @:noCompletion private var $state:tink.state.Observable<$type>;
    });

    return {
      getter: macro this.$state.value,
      init: Skip,
      type: type,
    }
  }

  function mustNotHaveMetaArgs(ctx:FieldContext) 
    switch ctx.meta.params {
      case []:
      case v: 
        v[0].reject('@:${ctx.meta.name} must not have arguments');
    }

  function observableField(ctx:FieldContext, setter:Bool):Result {
    var name = ctx.name,
        state = stateOf(name);

    return {
      getter: macro @:pos(ctx.pos) this.$state.value,
      setter: if (setter) macro @:pos(ctx.pos) this.$state.set(param) else null,
      stateful: true,
      transitionable: !setter,
      init: switch ctx.expr {
        case null: Arg();
        case macro @byDefault $v: OptArg(v);
        case v: Value(v);
      },
    }
  }
}
