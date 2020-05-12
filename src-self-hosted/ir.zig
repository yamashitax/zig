const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const LinkedList = std.TailQueue;
const Value = @import("value.zig").Value;
const Type = @import("type.zig").Type;
const TypedValue = @import("TypedValue.zig");
const assert = std.debug.assert;
const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const Target = std.Target;
const Package = @import("Package.zig");
const link = @import("link.zig");

pub const text = @import("ir/text.zig");

/// These are in-memory, analyzed instructions. See `text.Inst` for the representation
/// of instructions that correspond to the ZIR text format.
/// This struct owns the `Value` and `Type` memory. When the struct is deallocated,
/// so are the `Value` and `Type`. The value of a constant must be copied into
/// a memory location for the value to survive after a const instruction.
pub const Inst = struct {
    tag: Tag,
    ty: Type,
    /// Byte offset into the source.
    src: usize,

    pub const Tag = enum {
        assembly,
        bitcast,
        breakpoint,
        call,
        cmp,
        condbr,
        constant,
        isnonnull,
        isnull,
        ptrtoint,
        ret,
        unreach,
    };

    pub fn cast(base: *Inst, comptime T: type) ?*T {
        if (base.tag != T.base_tag)
            return null;

        return @fieldParentPtr(T, "base", base);
    }

    pub fn Args(comptime T: type) type {
        return std.meta.fieldInfo(T, "args").field_type;
    }

    /// Returns `null` if runtime-known.
    pub fn value(base: *Inst) ?Value {
        if (base.ty.onePossibleValue())
            return Value.initTag(.the_one_possible_value);

        const inst = base.cast(Constant) orelse return null;
        return inst.val;
    }

    pub const Assembly = struct {
        pub const base_tag = Tag.assembly;
        base: Inst,

        args: struct {
            asm_source: []const u8,
            is_volatile: bool,
            output: ?[]const u8,
            inputs: []const []const u8,
            clobbers: []const []const u8,
            args: []const *Inst,
        },
    };

    pub const BitCast = struct {
        pub const base_tag = Tag.bitcast;

        base: Inst,
        args: struct {
            operand: *Inst,
        },
    };

    pub const Breakpoint = struct {
        pub const base_tag = Tag.breakpoint;
        base: Inst,
        args: void,
    };

    pub const Call = struct {
        pub const base_tag = Tag.call;
        base: Inst,
        args: struct {
            func: *Inst,
            args: []const *Inst,
        },
    };

    pub const Cmp = struct {
        pub const base_tag = Tag.cmp;

        base: Inst,
        args: struct {
            lhs: *Inst,
            op: std.math.CompareOperator,
            rhs: *Inst,
        },
    };

    pub const CondBr = struct {
        pub const base_tag = Tag.condbr;

        base: Inst,
        args: struct {
            condition: *Inst,
            true_body: Module.Body,
            false_body: Module.Body,
        },
    };

    pub const Constant = struct {
        pub const base_tag = Tag.constant;
        base: Inst,

        val: Value,
    };

    pub const IsNonNull = struct {
        pub const base_tag = Tag.isnonnull;

        base: Inst,
        args: struct {
            operand: *Inst,
        },
    };

    pub const IsNull = struct {
        pub const base_tag = Tag.isnull;

        base: Inst,
        args: struct {
            operand: *Inst,
        },
    };

    pub const PtrToInt = struct {
        pub const base_tag = Tag.ptrtoint;

        base: Inst,
        args: struct {
            ptr: *Inst,
        },
    };

    pub const Ret = struct {
        pub const base_tag = Tag.ret;
        base: Inst,
        args: void,
    };

    pub const Unreach = struct {
        pub const base_tag = Tag.unreach;
        base: Inst,
        args: void,
    };
};

fn swapRemoveElem(allocator: *Allocator, comptime T: type, item: T, list: *ArrayListUnmanaged(T)) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i] == item) {
            list.swapRemove(allocator, i);
            continue;
        }
        i += 1;
    }
}

pub const Module = struct {
    /// General-purpose allocator.
    allocator: *Allocator,
    /// Module owns this resource.
    root_pkg: *Package,
    /// Module owns this resource.
    root_scope: *Scope.ZIRModule,
    /// Pointer to externally managed resource.
    bin_file: *link.ElfFile,
    /// It's rare for a decl to be exported, so we save memory by having a sparse map of
    /// Decl pointers to details about them being exported.
    /// The Export memory is owned by the `export_owners` table; the slice itself is owned by this table.
    decl_exports: std.AutoHashMap(*Decl, []*Export),
    /// This models the Decls that perform exports, so that `decl_exports` can be updated when a Decl
    /// is modified. Note that the key of this table is not the Decl being exported, but the Decl that
    /// is performing the export of another Decl.
    /// This table owns the Export memory.
    export_owners: std.AutoHashMap(*Decl, []*Export),
    /// Maps fully qualified namespaced names to the Decl struct for them.
    decl_table: std.AutoHashMap(Decl.Hash, *Decl),

    optimize_mode: std.builtin.Mode,
    link_error_flags: link.ElfFile.ErrorFlags = .{},

    /// We optimize memory usage for a compilation with no compile errors by storing the
    /// error messages and mapping outside of `Decl`.
    /// The ErrorMsg memory is owned by the decl, using Module's allocator.
    failed_decls: std.AutoHashMap(*Decl, *ErrorMsg),
    /// We optimize memory usage for a compilation with no compile errors by storing the
    /// error messages and mapping outside of `Fn`.
    /// The ErrorMsg memory is owned by the `Fn`, using Module's allocator.
    failed_fns: std.AutoHashMap(*Fn, *ErrorMsg),
    /// Using a map here for consistency with the other fields here.
    /// The ErrorMsg memory is owned by the `Scope.ZIRModule`, using Module's allocator.
    failed_files: std.AutoHashMap(*Scope.ZIRModule, *ErrorMsg),
    /// Using a map here for consistency with the other fields here.
    /// The ErrorMsg memory is owned by the `Export`, using Module's allocator.
    failed_exports: std.AutoHashMap(*Export, *ErrorMsg),

    pub const Export = struct {
        options: std.builtin.ExportOptions,
        /// Byte offset into the file that contains the export directive.
        src: usize,
        /// Represents the position of the export, if any, in the output file.
        link: link.ElfFile.Export,
        /// The Decl that performs the export. Note that this is *not* the Decl being exported.
        owner_decl: *Decl,
        status: enum { in_progress, failed, complete },
    };

    pub const Decl = struct {
        /// This name is relative to the containing namespace of the decl. It uses a null-termination
        /// to save bytes, since there can be a lot of decls in a compilation. The null byte is not allowed
        /// in symbol names, because executable file formats use null-terminated strings for symbol names.
        /// All Decls have names, even values that are not bound to a zig namespace. This is necessary for
        /// mapping them to an address in the output file.
        /// Memory owned by this decl, using Module's allocator.
        name: [*:0]const u8,
        /// The direct parent container of the Decl. This field will need to get more fleshed out when
        /// self-hosted supports proper struct types and Zig AST => ZIR.
        /// Reference to externally owned memory.
        scope: *Scope.ZIRModule,
        /// Byte offset into the source file that contains this declaration.
        /// This is the base offset that src offsets within this Decl are relative to.
        src: usize,
        /// The most recent value of the Decl after a successful semantic analysis.
        /// The tag for this union is determined by the tag value of the analysis field.
        typed_value: union {
            never_succeeded,
            most_recent: TypedValue.Managed,
        },
        /// Represents the "shallow" analysis status. For example, for decls that are functions,
        /// the function type is analyzed with this set to `in_progress`, however, the semantic
        /// analysis of the function body is performed with this value set to `success`. Functions
        /// have their own analysis status field.
        analysis: enum {
            initial_in_progress,
            /// This Decl might be OK but it depends on another one which did not successfully complete
            /// semantic analysis. This Decl never had a value computed.
            initial_dependency_failure,
            /// Semantic analysis failure. This Decl never had a value computed.
            /// There will be a corresponding ErrorMsg in Module.failed_decls.
            initial_sema_failure,
            /// In this case the `typed_value.most_recent` can still be accessed.
            /// There will be a corresponding ErrorMsg in Module.failed_decls.
            codegen_failure,
            /// This Decl might be OK but it depends on another one which did not successfully complete
            /// semantic analysis. There is a most recent value available.
            repeat_dependency_failure,
            /// Semantic anlaysis failure, but the `typed_value.most_recent` can be accessed.
            /// There will be a corresponding ErrorMsg in Module.failed_decls.
            repeat_sema_failure,
            /// Completed successfully before; the `typed_value.most_recent` can be accessed, and
            /// new semantic analysis is in progress.
            repeat_in_progress,
            /// Everything is done and updated.
            complete,
        },

        /// Represents the position of the code, if any, in the output file.
        /// This is populated regardless of semantic analysis and code generation.
        /// This value is `undefined` if the type has no runtime bits.
        link: link.ElfFile.Decl,

        /// The set of other decls whose typed_value could possibly change if this Decl's
        /// typed_value is modified.
        /// TODO look into using a lightweight map/set data structure rather than a linear array.
        dependants: ArrayListUnmanaged(*Decl) = .{},

        pub fn typedValue(self: Decl) ?TypedValue {
            switch (self.analysis) {
                .initial_in_progress,
                .initial_dependency_failure,
                .initial_sema_failure,
                => return null,
                .codegen_failure,
                .repeat_dependency_failure,
                .repeat_sema_failure,
                .repeat_in_progress,
                .complete,
                => return self.typed_value.most_recent,
            }
        }

        pub fn destroy(self: *Decl, allocator: *Allocator) void {
            allocator.free(mem.spanZ(u8, self.name));
            if (self.typedValue()) |tv| tv.deinit(allocator);
            allocator.destroy(self);
        }

        pub const Hash = [16]u8;

        /// Must generate unique bytes with no collisions with other decls.
        /// The point of hashing here is only to limit the number of bytes of
        /// the unique identifier to a fixed size (16 bytes).
        pub fn fullyQualifiedNameHash(self: Decl) Hash {
            // Right now we only have ZIRModule as the source. So this is simply the
            // relative name of the decl.
            var out: Hash = undefined;
            std.crypto.Blake3.hash(mem.spanZ(u8, self.name), &out);
            return out;
        }
    };

    /// Memory is managed by the arena of the owning Decl.
    pub const Fn = struct {
        fn_type: Type,
        analysis: union(enum) {
            queued,
            in_progress: *Analysis,
            /// There will be a corresponding ErrorMsg in Module.failed_fns
            failure,
            success: Body,
        },
        /// The direct container of the Fn. This field will need to get more fleshed out when
        /// self-hosted supports proper struct types and Zig AST => ZIR.
        scope: *Scope.ZIRModule,

        /// This memory managed by the general purpose allocator.
        pub const Analysis = struct {
            inner_block: Scope.Block,
            /// null value means a semantic analysis error happened.
            inst_table: std.AutoHashMap(*text.Inst, ?*Inst),
        };
    };

    pub const Scope = struct {
        tag: Tag,

        pub fn cast(base: *Scope, comptime T: type) ?*T {
            if (base.tag != T.base_tag)
                return null;

            return @fieldParentPtr(T, "base", base);
        }

        pub const Tag = enum {
            zir_module,
            block,
            decl,
        };

        pub const ZIRModule = struct {
            pub const base_tag: Tag = .zir_module;
            base: Scope = Scope{ .tag = base_tag },
            /// Relative to the owning package's root_src_dir.
            /// Reference to external memory, not owned by ZIRModule.
            sub_file_path: []const u8,
            source: union {
                unloaded,
                bytes: [:0]const u8,
            },
            contents: union {
                not_available,
                module: *text.Module,
            },
            status: enum {
                unloaded,
                unloaded_parse_failure,
                loaded_parse_failure,
                loaded_success,
            },

            pub fn deinit(self: *ZIRModule, allocator: *Allocator) void {
                switch (self.status) {
                    .unloaded,
                    .unloaded_parse_failure,
                    => {},
                    .loaded_success => {
                        allocator.free(contents.source);
                        self.contents.module.deinit(allocator);
                    },
                    .loaded_parse_failure => {
                        allocator.free(contents.source);
                    },
                }
                self.* = undefined;
            }
        };

        /// This is a temporary structure, references to it are valid only
        /// during semantic analysis of the block.
        pub const Block = struct {
            pub const base_tag: Tag = .block;
            base: Scope = Scope{ .tag = base_tag },
            func: *Fn,
            instructions: ArrayListUnmanaged(*Inst),
        };

        /// This is a temporary structure, references to it are valid only
        /// during semantic analysis of the decl.
        pub const DeclAnalysis = struct {
            pub const base_tag: Tag = .decl;
            base: Scope = Scope{ .tag = base_tag },
            decl: *Decl,
        };
    };

    pub const Body = struct {
        instructions: []*Inst,
    };

    pub const AllErrors = struct {
        arena: std.heap.ArenaAllocator.State,
        list: []const Message,

        pub const Message = struct {
            src_path: []const u8,
            line: usize,
            column: usize,
            byte_offset: usize,
            msg: []const u8,
        };

        pub fn deinit(self: *AllErrors, allocator: *Allocator) void {
            self.arena.promote(allocator).deinit();
        }

        fn add(
            arena: *std.heap.ArenaAllocator,
            errors: *std.ArrayList(Message),
            sub_file_path: []const u8,
            source: []const u8,
            simple_err_msg: ErrorMsg,
        ) !void {
            const loc = std.zig.findLineColumn(source, simple_err_msg.byte_offset);
            try errors.append(.{
                .src_path = try mem.dupe(u8, &arena.allocator, sub_file_path),
                .msg = try mem.dupe(u8, &arena.allocator, simple_err_msg.msg),
                .byte_offset = simple_err_msg.byte_offset,
                .line = loc.line,
                .column = loc.column,
            });
        }
    };

    pub fn deinit(self: *Module) void {
        const allocator = self.allocator;
        allocator.free(self.errors);
        {
            var it = self.decl_table.iterator();
            while (it.next()) |kv| {
                kv.value.destroy(allocator);
            }
            self.decl_table.deinit();
        }
        self.root_pkg.destroy();
        self.root_scope.deinit();
        self.* = undefined;
    }

    pub fn target(self: Module) std.Target {
        return self.bin_file.options.target;
    }

    /// Detect changes to source files, perform semantic analysis, and update the output files.
    pub fn update(self: *Module) !void {
        // TODO Use the cache hash file system to detect which source files changed.
        // Here we simulate a full cache miss.
        // Analyze the root source file now.
        self.analyzeRoot(self.root_scope) catch |err| switch (err) {
            error.AnalysisFail => {
                assert(self.failed_files.size != 0);
            },
            else => |e| return e,
        };

        try self.bin_file.flush();
        self.link_error_flags = self.bin_file.error_flags;
    }

    pub fn totalErrorCount(self: *Module) usize {
        return self.failed_decls.size +
            self.failed_fns.size +
            self.failed_decls.size +
            self.failed_exports.size +
            @boolToInt(self.link_error_flags.no_entry_point_found);
    }

    pub fn getAllErrorsAlloc(self: *Module) !AllErrors {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        var errors = std.ArrayList(AllErrors.Message).init(self.allocator);
        defer errors.deinit();

        {
            var it = self.failed_files.iterator();
            while (it.next()) |kv| {
                const scope = kv.key;
                const err_msg = kv.value;
                const source = scope.parse_failure.source;
                AllErrors.add(&arena, &errors, scope.sub_file_path, source, err_msg);
            }
        }
        {
            var it = self.failed_fns.iterator();
            while (it.next()) |kv| {
                const func = kv.key;
                const err_msg = kv.value;
                const source = func.scope.success.source;
                AllErrors.add(&arena, &errors, func.scope.sub_file_path, source, err_msg);
            }
        }
        {
            var it = self.failed_decls.iterator();
            while (it.next()) |kv| {
                const decl = kv.key;
                const err_msg = kv.value;
                const source = decl.scope.success.source;
                AllErrors.add(&arena, &errors, decl.scope.sub_file_path, source, err_msg);
            }
        }
        {
            var it = self.failed_exports.iterator();
            while (it.next()) |kv| {
                const decl = kv.key.owner_decl;
                const err_msg = kv.value;
                const source = decl.scope.success.source;
                try AllErrors.add(&arena, &errors, decl.scope.sub_file_path, source, err_msg);
            }
        }

        if (self.link_error_flags.no_entry_point_found) {
            try errors.append(.{
                .src_path = self.module.root_src_path,
                .line = 0,
                .column = 0,
                .byte_offset = 0,
                .msg = try std.fmt.allocPrint(&arena.allocator, "no entry point found", .{}),
            });
        }

        assert(errors.items.len == self.totalErrorCount());

        return AllErrors{
            .arena = arena.state,
            .list = try mem.dupe(&arena.allocator, AllErrors.Message, errors.items),
        };
    }

    const InnerError = error{ OutOfMemory, AnalysisFail };

    fn analyzeRoot(self: *Module, root_scope: *Scope.ZIRModule) !void {
        // TODO use the cache to identify, from the modified source files, the decls which have
        // changed based on the span of memory that represents the decl in the re-parsed source file.
        // Use the cached dependency graph to recursively determine the set of decls which need
        // regeneration.
        // Here we simulate adding a source file which was previously not part of the compilation,
        // which means scanning the decls looking for exports.
        // TODO also identify decls that need to be deleted.
        const src_module = switch (root_scope.status) {
            .unloaded => blk: {
                try self.failed_files.ensureCapacity(self.failed_files.size + 1);

                var keep_source = false;
                const source = try self.root_pkg_dir.readFileAllocOptions(
                    self.allocator,
                    self.root_src_path,
                    std.math.maxInt(u32),
                    1,
                    0,
                );
                defer if (!keep_source) self.allocator.free(source);

                var keep_zir_module = false;
                const zir_module = try self.allocator.create(text.Module);
                defer if (!keep_zir_module) self.allocator.destroy(zir_module);

                zir_module.* = try text.parse(self.allocator, source);
                defer if (!keep_zir_module) zir_module.deinit(self.allocator);

                if (zir_module.error_msg) |src_err_msg| {
                    self.failed_files.putAssumeCapacityNoClobber(
                        root_scope,
                        try ErrorMsg.create(self.allocator, src_err_msg.byte_offset, "{}", .{src_err_msg.msg}),
                    );
                    root_scope.status = .loaded_parse_failure;
                    root_scope.source = .{ .bytes = source };
                    keep_source = true;
                    return error.AnalysisFail;
                }

                root_scope.status = .loaded_success;
                root_scope.source = .{ .bytes = source };
                keep_source = true;
                root_scope.contents = .{ .module = zir_module };
                keep_zir_module = true;

                break :blk zir_module;
            },

            .unloaded_parse_failure, .loaded_parse_failure => return error.AnalysisFail,
            .loaded_success => root_scope.contents.module,
        };

        // Here we ensure enough queue capacity to store all the decls, so that later we can use
        // appendAssumeCapacity.
        try self.analysis_queue.ensureCapacity(self.analysis_queue.items.len + contents.module.decls.len);

        for (contents.module.decls) |decl| {
            if (decl.cast(text.Inst.Export)) |export_inst| {
                try analyzeExport(self, &root_scope.base, export_inst);
            }
        }

        while (self.analysis_queue.popOrNull()) |work_item| {
            switch (work_item) {
                .decl => |decl| switch (decl.analysis) {
                    .success => |typed_value| {
                        var arena = decl.arena.promote(self.allocator);
                        const update_result = self.bin_file.updateDecl(
                            self.*,
                            typed_value,
                            decl.export_node,
                            decl.fullyQualifiedNameHash(),
                            &arena.allocator,
                        );
                        decl.arena = arena.state;
                        if (try update_result) |err_msg| {
                            decl.analysis = .{ .codegen_failure = err_msg };
                        }
                    },
                },
            }
        }
    }

    fn resolveDecl(self: *Module, scope: *Scope, old_inst: *text.Inst) InnerError!*Decl {
        const hash = old_inst.fullyQualifiedNameHash();
        if (self.decl_table.get(hash)) |kv| {
            return kv.value;
        } else {
            const new_decl = blk: {
                var decl_arena = std.heap.ArenaAllocator.init(self.allocator);
                errdefer decl_arena.deinit();
                const new_decl = try decl_arena.allocator.create(Decl);
                const name = try mem.dupeZ(&decl_arena.allocator, u8, old_inst.name);
                new_decl.* = .{
                    .arena = decl_arena.state,
                    .name = name,
                    .src = old_inst.src,
                    .analysis = .in_progress,
                    .scope = scope.findZIRModule(),
                };
                try self.decl_table.putNoClobber(hash, new_decl);
                break :blk new_decl;
            };

            swapRemoveElem(self.allocator, *Scope.ZIRModule, root_scope, self.failed_decls);
            var decl_scope: Scope.DeclAnalysis = .{
                .base = .{ .parent = scope },
                .decl = new_decl,
            };
            const typed_value = self.analyzeInstConst(&decl_scope.base, old_inst) catch |err| switch (err) {
                error.AnalysisFail => {
                    assert(new_decl.analysis == .failure);
                    return error.AnalysisFail;
                },
                else => |e| return e,
            };
            new_decl.analysis = .{ .success = typed_value };
            // We ensureCapacity when scanning for decls.
            self.analysis_queue.appendAssumeCapacity(.{ .decl = new_decl });
            return new_decl;
        }
    }

    fn resolveCompleteDecl(self: *Module, scope: *Scope, old_inst: *text.Inst) InnerError!*Decl {
        const decl = try self.resolveDecl(scope, old_inst);
        switch (decl.analysis) {
            .initial_in_progress => unreachable,
            .repeat_in_progress => unreachable,
            .initial_dependency_failure,
            .repeat_dependency_failure,
            .initial_sema_failure,
            .repeat_sema_failure,
            .codegen_failure,
            => return error.AnalysisFail,

            .complete => return decl,
        }
    }

    fn resolveInst(self: *Module, scope: *Scope, old_inst: *text.Inst) InnerError!*Inst {
        if (scope.cast(Scope.Block)) |block| {
            if (block.func.inst_table.get(old_inst)) |kv| {
                return kv.value.ptr orelse return error.AnalysisFail;
            }
        }

        const decl = try self.resolveCompleteDecl(scope, old_inst);
        const decl_ref = try self.analyzeDeclRef(scope, old_inst.src, decl);
        return self.analyzeDeref(scope, old_inst.src, decl_ref);
    }

    fn requireRuntimeBlock(self: *Module, scope: *Scope, src: usize) !*Scope.Block {
        return scope.cast(Scope.Block) orelse
            return self.fail(scope, src, "instruction illegal outside function body", .{});
    }

    fn resolveInstConst(self: *Module, scope: *Scope, old_inst: *text.Inst) InnerError!TypedValue {
        const new_inst = try self.resolveInst(scope, old_inst);
        const val = try self.resolveConstValue(new_inst);
        return TypedValue{
            .ty = new_inst.ty,
            .val = val,
        };
    }

    fn resolveConstValue(self: *Module, scope: *Scope, base: *Inst) !Value {
        return (try self.resolveDefinedValue(base)) orelse
            return self.fail(scope, base.src, "unable to resolve comptime value", .{});
    }

    fn resolveDefinedValue(self: *Module, scope: *Scope, base: *Inst) !?Value {
        if (base.value()) |val| {
            if (val.isUndef()) {
                return self.fail(scope, base.src, "use of undefined value here causes undefined behavior", .{});
            }
            return val;
        }
        return null;
    }

    fn resolveConstString(self: *Module, scope: *Scope, old_inst: *text.Inst) ![]u8 {
        const new_inst = try self.resolveInst(scope, old_inst);
        const wanted_type = Type.initTag(.const_slice_u8);
        const coerced_inst = try self.coerce(scope, wanted_type, new_inst);
        const val = try self.resolveConstValue(coerced_inst);
        return val.toAllocatedBytes(&self.arena.allocator);
    }

    fn resolveType(self: *Module, scope: *Scope, old_inst: *text.Inst) !Type {
        const new_inst = try self.resolveInst(scope, old_inst);
        const wanted_type = Type.initTag(.@"type");
        const coerced_inst = try self.coerce(scope, wanted_type, new_inst);
        const val = try self.resolveConstValue(coerced_inst);
        return val.toType();
    }

    fn analyzeExport(self: *Module, scope: *Scope, export_inst: *text.Inst.Export) !void {
        try self.decl_exports.ensureCapacity(self.decl_exports.size + 1);
        try self.export_owners.ensureCapacity(self.export_owners.size + 1);
        const symbol_name = try self.resolveConstString(scope, export_inst.positionals.symbol_name);
        const exported_decl = try self.resolveCompleteDecl(scope, export_inst.positionals.value);
        const typed_value = exported_decl.typed_value.most_recent.typed_value;
        switch (typed_value.ty.zigTypeTag()) {
            .Fn => {},
            else => return self.fail(
                scope,
                export_inst.positionals.value.src,
                "unable to export type '{}'",
                .{typed_value.ty},
            ),
        }
        const new_export = try self.allocator.create(Export);
        errdefer self.allocator.destroy(new_export);

        const owner_decl = scope.getDecl();

        new_export.* = .{
            .options = .{ .data = .{ .name = symbol_name } },
            .src = export_inst.base.src,
            .link = .{},
            .owner_decl = owner_decl,
            .status = .in_progress,
        };

        // Add to export_owners table.
        const eo_gop = self.export_owners.getOrPut(owner_decl) catch unreachable;
        if (!eo_gop.found_existing) {
            eo_gop.kv.value = &[0]*Export{};
        }
        eo_gop.kv.value = try self.allocator.realloc(eo_gop.kv.value, eo_gop.kv.value.len + 1);
        eo_gop.kv.value[eo_gop.kv.value.len - 1] = new_export;
        errdefer eo_gop.kv.value = self.allocator.shrink(eo_gop.kv.value, eo_gop.kv.value.len - 1);

        // Add to exported_decl table.
        const de_gop = self.decl_exports.getOrPut(exported_decl) catch unreachable;
        if (!de_gop.found_existing) {
            de_gop.kv.value = &[0]*Export{};
        }
        de_gop.kv.value = try self.allocator.realloc(de_gop.kv.value, de_gop.kv.value.len + 1);
        de_gop.kv.value[de_gop.kv.value.len - 1] = new_export;
        errdefer de_gop.kv.value = self.allocator.shrink(de_gop.kv.value, de_gop.kv.value.len - 1);

        try self.bin_file.updateDeclExports(self, decl, de_gop.kv.value);
    }

    /// TODO should not need the cast on the last parameter at the callsites
    fn addNewInstArgs(
        self: *Module,
        block: *Scope.Block,
        src: usize,
        ty: Type,
        comptime T: type,
        args: Inst.Args(T),
    ) !*Inst {
        const inst = try self.addNewInst(block, src, ty, T);
        inst.args = args;
        return &inst.base;
    }

    fn addNewInst(self: *Module, block: *Scope.Block, src: usize, ty: Type, comptime T: type) !*T {
        const inst = try self.arena.allocator.create(T);
        inst.* = .{
            .base = .{
                .tag = T.base_tag,
                .ty = ty,
                .src = src,
            },
            .args = undefined,
        };
        try block.instructions.append(self.allocator, &inst.base);
        return inst;
    }

    fn constInst(self: *Module, src: usize, typed_value: TypedValue) !*Inst {
        const const_inst = try self.arena.allocator.create(Inst.Constant);
        const_inst.* = .{
            .base = .{
                .tag = Inst.Constant.base_tag,
                .ty = typed_value.ty,
                .src = src,
            },
            .val = typed_value.val,
        };
        return &const_inst.base;
    }

    fn constStr(self: *Module, src: usize, str: []const u8) !*Inst {
        const array_payload = try self.arena.allocator.create(Type.Payload.Array_u8_Sentinel0);
        array_payload.* = .{ .len = str.len };

        const ty_payload = try self.arena.allocator.create(Type.Payload.SingleConstPointer);
        ty_payload.* = .{ .pointee_type = Type.initPayload(&array_payload.base) };

        const bytes_payload = try self.arena.allocator.create(Value.Payload.Bytes);
        bytes_payload.* = .{ .data = str };

        return self.constInst(src, .{
            .ty = Type.initPayload(&ty_payload.base),
            .val = Value.initPayload(&bytes_payload.base),
        });
    }

    fn constType(self: *Module, src: usize, ty: Type) !*Inst {
        return self.constInst(src, .{
            .ty = Type.initTag(.type),
            .val = try ty.toValue(&self.arena.allocator),
        });
    }

    fn constVoid(self: *Module, src: usize) !*Inst {
        return self.constInst(src, .{
            .ty = Type.initTag(.void),
            .val = Value.initTag(.the_one_possible_value),
        });
    }

    fn constUndef(self: *Module, src: usize, ty: Type) !*Inst {
        return self.constInst(src, .{
            .ty = ty,
            .val = Value.initTag(.undef),
        });
    }

    fn constBool(self: *Module, src: usize, v: bool) !*Inst {
        return self.constInst(src, .{
            .ty = Type.initTag(.bool),
            .val = ([2]Value{ Value.initTag(.bool_false), Value.initTag(.bool_true) })[@boolToInt(v)],
        });
    }

    fn constIntUnsigned(self: *Module, src: usize, ty: Type, int: u64) !*Inst {
        const int_payload = try self.arena.allocator.create(Value.Payload.Int_u64);
        int_payload.* = .{ .int = int };

        return self.constInst(src, .{
            .ty = ty,
            .val = Value.initPayload(&int_payload.base),
        });
    }

    fn constIntSigned(self: *Module, src: usize, ty: Type, int: i64) !*Inst {
        const int_payload = try self.arena.allocator.create(Value.Payload.Int_i64);
        int_payload.* = .{ .int = int };

        return self.constInst(src, .{
            .ty = ty,
            .val = Value.initPayload(&int_payload.base),
        });
    }

    fn constIntBig(self: *Module, src: usize, ty: Type, big_int: BigIntConst) !*Inst {
        const val_payload = if (big_int.positive) blk: {
            if (big_int.to(u64)) |x| {
                return self.constIntUnsigned(src, ty, x);
            } else |err| switch (err) {
                error.NegativeIntoUnsigned => unreachable,
                error.TargetTooSmall => {}, // handled below
            }
            const big_int_payload = try self.arena.allocator.create(Value.Payload.IntBigPositive);
            big_int_payload.* = .{ .limbs = big_int.limbs };
            break :blk &big_int_payload.base;
        } else blk: {
            if (big_int.to(i64)) |x| {
                return self.constIntSigned(src, ty, x);
            } else |err| switch (err) {
                error.NegativeIntoUnsigned => unreachable,
                error.TargetTooSmall => {}, // handled below
            }
            const big_int_payload = try self.arena.allocator.create(Value.Payload.IntBigNegative);
            big_int_payload.* = .{ .limbs = big_int.limbs };
            break :blk &big_int_payload.base;
        };

        return self.constInst(src, .{
            .ty = ty,
            .val = Value.initPayload(val_payload),
        });
    }

    fn analyzeInstConst(self: *Module, scope: *Scope, old_inst: *text.Inst) InnerError!TypedValue {
        const new_inst = try self.analyzeInst(scope, old_inst);
        return TypedValue{
            .ty = new_inst.ty,
            .val = try self.resolveConstValue(scope, new_inst),
        };
    }

    fn analyzeInst(self: *Module, scope: *Scope, old_inst: *text.Inst) InnerError!*Inst {
        switch (old_inst.tag) {
            .breakpoint => return self.analyzeInstBreakpoint(scope, old_inst.cast(text.Inst.Breakpoint).?),
            .call => return self.analyzeInstCall(scope, old_inst.cast(text.Inst.Call).?),
            .str => {
                // We can use this reference because Inst.Const's Value is arena-allocated.
                // The value would get copied to a MemoryCell before the `text.Inst.Str` lifetime ends.
                const bytes = old_inst.cast(text.Inst.Str).?.positionals.bytes;
                return self.constStr(old_inst.src, bytes);
            },
            .int => {
                const big_int = old_inst.cast(text.Inst.Int).?.positionals.int;
                return self.constIntBig(old_inst.src, Type.initTag(.comptime_int), big_int);
            },
            .ptrtoint => return self.analyzeInstPtrToInt(scope, old_inst.cast(text.Inst.PtrToInt).?),
            .fieldptr => return self.analyzeInstFieldPtr(scope, old_inst.cast(text.Inst.FieldPtr).?),
            .deref => return self.analyzeInstDeref(scope, old_inst.cast(text.Inst.Deref).?),
            .as => return self.analyzeInstAs(scope, old_inst.cast(text.Inst.As).?),
            .@"asm" => return self.analyzeInstAsm(scope, old_inst.cast(text.Inst.Asm).?),
            .@"unreachable" => return self.analyzeInstUnreachable(scope, old_inst.cast(text.Inst.Unreachable).?),
            .@"return" => return self.analyzeInstRet(scope, old_inst.cast(text.Inst.Return).?),
            // TODO postpone function analysis until later
            .@"fn" => return self.analyzeInstFn(scope, old_inst.cast(text.Inst.Fn).?),
            .@"export" => {
                try self.analyzeExport(scope, old_inst.cast(text.Inst.Export).?);
                return self.constVoid(old_inst.src);
            },
            .primitive => return self.analyzeInstPrimitive(old_inst.cast(text.Inst.Primitive).?),
            .fntype => return self.analyzeInstFnType(scope, old_inst.cast(text.Inst.FnType).?),
            .intcast => return self.analyzeInstIntCast(scope, old_inst.cast(text.Inst.IntCast).?),
            .bitcast => return self.analyzeInstBitCast(scope, old_inst.cast(text.Inst.BitCast).?),
            .elemptr => return self.analyzeInstElemPtr(scope, old_inst.cast(text.Inst.ElemPtr).?),
            .add => return self.analyzeInstAdd(scope, old_inst.cast(text.Inst.Add).?),
            .cmp => return self.analyzeInstCmp(scope, old_inst.cast(text.Inst.Cmp).?),
            .condbr => return self.analyzeInstCondBr(scope, old_inst.cast(text.Inst.CondBr).?),
            .isnull => return self.analyzeInstIsNull(scope, old_inst.cast(text.Inst.IsNull).?),
            .isnonnull => return self.analyzeInstIsNonNull(scope, old_inst.cast(text.Inst.IsNonNull).?),
        }
    }

    fn analyzeInstBreakpoint(self: *Module, scope: *Scope, inst: *text.Inst.Breakpoint) InnerError!*Inst {
        const b = try self.requireRuntimeBlock(scope, inst.base.src);
        return self.addNewInstArgs(b, inst.base.src, Type.initTag(.void), Inst.Breakpoint, Inst.Args(Inst.Breakpoint){});
    }

    fn analyzeInstCall(self: *Module, scope: *Scope, inst: *text.Inst.Call) InnerError!*Inst {
        const func = try self.resolveInst(scope, inst.positionals.func);
        if (func.ty.zigTypeTag() != .Fn)
            return self.fail(scope, inst.positionals.func.src, "type '{}' not a function", .{func.ty});

        const cc = func.ty.fnCallingConvention();
        if (cc == .Naked) {
            // TODO add error note: declared here
            return self.fail(
                scope,
                inst.positionals.func.src,
                "unable to call function with naked calling convention",
                .{},
            );
        }
        const call_params_len = inst.positionals.args.len;
        const fn_params_len = func.ty.fnParamLen();
        if (func.ty.fnIsVarArgs()) {
            if (call_params_len < fn_params_len) {
                // TODO add error note: declared here
                return self.fail(
                    scope,
                    inst.positionals.func.src,
                    "expected at least {} arguments, found {}",
                    .{ fn_params_len, call_params_len },
                );
            }
            return self.fail(scope, inst.base.src, "TODO implement support for calling var args functions", .{});
        } else if (fn_params_len != call_params_len) {
            // TODO add error note: declared here
            return self.fail(
                scope,
                inst.positionals.func.src,
                "expected {} arguments, found {}",
                .{ fn_params_len, call_params_len },
            );
        }

        if (inst.kw_args.modifier == .compile_time) {
            return self.fail(scope, inst.base.src, "TODO implement comptime function calls", .{});
        }
        if (inst.kw_args.modifier != .auto) {
            return self.fail(scope, inst.base.src, "TODO implement call with modifier {}", .{inst.kw_args.modifier});
        }

        // TODO handle function calls of generic functions

        const fn_param_types = try self.allocator.alloc(Type, fn_params_len);
        defer self.allocator.free(fn_param_types);
        func.ty.fnParamTypes(fn_param_types);

        const casted_args = try self.arena.allocator.alloc(*Inst, fn_params_len);
        for (inst.positionals.args) |src_arg, i| {
            const uncasted_arg = try self.resolveInst(scope, src_arg);
            casted_args[i] = try self.coerce(scope, fn_param_types[i], uncasted_arg);
        }

        const b = try self.requireRuntimeBlock(scope, inst.base.src);
        return self.addNewInstArgs(b, inst.base.src, Type.initTag(.void), Inst.Call, Inst.Args(Inst.Call){
            .func = func,
            .args = casted_args,
        });
    }

    fn analyzeInstFn(self: *Module, scope: *Scope, fn_inst: *text.Inst.Fn) InnerError!*Inst {
        const fn_type = try self.resolveType(scope, fn_inst.positionals.fn_type);

        var new_func: Fn = .{
            .fn_index = self.fns.items.len,
            .inner_block = .{
                .func = undefined,
                .instructions = .{},
            },
            .inst_table = std.AutoHashMap(*text.Inst, ?*Inst).init(self.allocator),
        };
        new_func.inner_block.func = &new_func;
        defer new_func.inner_block.instructions.deinit();
        defer new_func.inst_table.deinit();
        // Don't hang on to a reference to this when analyzing body instructions, since the memory
        // could become invalid.
        (try self.fns.addOne(self.allocator)).* = .{
            .analysis_status = .in_progress,
            .fn_type = fn_type,
            .body = undefined,
        };

        try self.analyzeBody(&new_func.inner_block, fn_inst.positionals.body);

        const f = &self.fns.items[new_func.fn_index];
        f.analysis_status = .success;
        f.body = .{ .instructions = new_func.inner_block.instructions.toOwnedSlice() };

        const fn_payload = try self.arena.allocator.create(Value.Payload.Function);
        fn_payload.* = .{ .index = new_func.fn_index };

        return self.constInst(fn_inst.base.src, .{
            .ty = fn_type,
            .val = Value.initPayload(&fn_payload.base),
        });
    }

    fn analyzeInstFnType(self: *Module, scope: *Scope, fntype: *text.Inst.FnType) InnerError!*Inst {
        const return_type = try self.resolveType(scope, fntype.positionals.return_type);

        if (return_type.zigTypeTag() == .NoReturn and
            fntype.positionals.param_types.len == 0 and
            fntype.kw_args.cc == .Unspecified)
        {
            return self.constType(fntype.base.src, Type.initTag(.fn_noreturn_no_args));
        }

        if (return_type.zigTypeTag() == .NoReturn and
            fntype.positionals.param_types.len == 0 and
            fntype.kw_args.cc == .Naked)
        {
            return self.constType(fntype.base.src, Type.initTag(.fn_naked_noreturn_no_args));
        }

        if (return_type.zigTypeTag() == .Void and
            fntype.positionals.param_types.len == 0 and
            fntype.kw_args.cc == .C)
        {
            return self.constType(fntype.base.src, Type.initTag(.fn_ccc_void_no_args));
        }

        return self.fail(scope, fntype.base.src, "TODO implement fntype instruction more", .{});
    }

    fn analyzeInstPrimitive(self: *Module, primitive: *text.Inst.Primitive) InnerError!*Inst {
        return self.constType(primitive.base.src, primitive.positionals.tag.toType());
    }

    fn analyzeInstAs(self: *Module, scope: *Scope, as: *text.Inst.As) InnerError!*Inst {
        const dest_type = try self.resolveType(scope, as.positionals.dest_type);
        const new_inst = try self.resolveInst(scope, as.positionals.value);
        return self.coerce(scope, dest_type, new_inst);
    }

    fn analyzeInstPtrToInt(self: *Module, scope: *Scope, ptrtoint: *text.Inst.PtrToInt) InnerError!*Inst {
        const ptr = try self.resolveInst(scope, ptrtoint.positionals.ptr);
        if (ptr.ty.zigTypeTag() != .Pointer) {
            return self.fail(scope, ptrtoint.positionals.ptr.src, "expected pointer, found '{}'", .{ptr.ty});
        }
        // TODO handle known-pointer-address
        const b = try self.requireRuntimeBlock(scope, ptrtoint.base.src);
        const ty = Type.initTag(.usize);
        return self.addNewInstArgs(b, ptrtoint.base.src, ty, Inst.PtrToInt, Inst.Args(Inst.PtrToInt){ .ptr = ptr });
    }

    fn analyzeInstFieldPtr(self: *Module, scope: *Scope, fieldptr: *text.Inst.FieldPtr) InnerError!*Inst {
        const object_ptr = try self.resolveInst(scope, fieldptr.positionals.object_ptr);
        const field_name = try self.resolveConstString(scope, fieldptr.positionals.field_name);

        const elem_ty = switch (object_ptr.ty.zigTypeTag()) {
            .Pointer => object_ptr.ty.elemType(),
            else => return self.fail(scope, fieldptr.positionals.object_ptr.src, "expected pointer, found '{}'", .{object_ptr.ty}),
        };
        switch (elem_ty.zigTypeTag()) {
            .Array => {
                if (mem.eql(u8, field_name, "len")) {
                    const len_payload = try self.arena.allocator.create(Value.Payload.Int_u64);
                    len_payload.* = .{ .int = elem_ty.arrayLen() };

                    const ref_payload = try self.arena.allocator.create(Value.Payload.RefVal);
                    ref_payload.* = .{ .val = Value.initPayload(&len_payload.base) };

                    return self.constInst(fieldptr.base.src, .{
                        .ty = Type.initTag(.single_const_pointer_to_comptime_int),
                        .val = Value.initPayload(&ref_payload.base),
                    });
                } else {
                    return self.fail(
                        scope,
                        fieldptr.positionals.field_name.src,
                        "no member named '{}' in '{}'",
                        .{ field_name, elem_ty },
                    );
                }
            },
            else => return self.fail(scope, fieldptr.base.src, "type '{}' does not support field access", .{elem_ty}),
        }
    }

    fn analyzeInstIntCast(self: *Module, scope: *Scope, intcast: *text.Inst.IntCast) InnerError!*Inst {
        const dest_type = try self.resolveType(scope, intcast.positionals.dest_type);
        const new_inst = try self.resolveInst(scope, intcast.positionals.value);

        const dest_is_comptime_int = switch (dest_type.zigTypeTag()) {
            .ComptimeInt => true,
            .Int => false,
            else => return self.fail(
                scope,
                intcast.positionals.dest_type.src,
                "expected integer type, found '{}'",
                .{
                    dest_type,
                },
            ),
        };

        switch (new_inst.ty.zigTypeTag()) {
            .ComptimeInt, .Int => {},
            else => return self.fail(
                scope,
                intcast.positionals.value.src,
                "expected integer type, found '{}'",
                .{new_inst.ty},
            ),
        }

        if (dest_is_comptime_int or new_inst.value() != null) {
            return self.coerce(scope, dest_type, new_inst);
        }

        return self.fail(scope, intcast.base.src, "TODO implement analyze widen or shorten int", .{});
    }

    fn analyzeInstBitCast(self: *Module, scope: *Scope, inst: *text.Inst.BitCast) InnerError!*Inst {
        const dest_type = try self.resolveType(scope, inst.positionals.dest_type);
        const operand = try self.resolveInst(scope, inst.positionals.operand);
        return self.bitcast(scope, dest_type, operand);
    }

    fn analyzeInstElemPtr(self: *Module, scope: *Scope, inst: *text.Inst.ElemPtr) InnerError!*Inst {
        const array_ptr = try self.resolveInst(scope, inst.positionals.array_ptr);
        const uncasted_index = try self.resolveInst(scope, inst.positionals.index);
        const elem_index = try self.coerce(scope, Type.initTag(.usize), uncasted_index);

        if (array_ptr.ty.isSinglePointer() and array_ptr.ty.elemType().zigTypeTag() == .Array) {
            if (array_ptr.value()) |array_ptr_val| {
                if (elem_index.value()) |index_val| {
                    // Both array pointer and index are compile-time known.
                    const index_u64 = index_val.toUnsignedInt();
                    // @intCast here because it would have been impossible to construct a value that
                    // required a larger index.
                    const elem_ptr = try array_ptr_val.elemPtr(&self.arena.allocator, @intCast(usize, index_u64));

                    const type_payload = try self.arena.allocator.create(Type.Payload.SingleConstPointer);
                    type_payload.* = .{ .pointee_type = array_ptr.ty.elemType().elemType() };

                    return self.constInst(inst.base.src, .{
                        .ty = Type.initPayload(&type_payload.base),
                        .val = elem_ptr,
                    });
                }
            }
        }

        return self.fail(scope, inst.base.src, "TODO implement more analyze elemptr", .{});
    }

    fn analyzeInstAdd(self: *Module, scope: *Scope, inst: *text.Inst.Add) InnerError!*Inst {
        const lhs = try self.resolveInst(scope, inst.positionals.lhs);
        const rhs = try self.resolveInst(scope, inst.positionals.rhs);

        if (lhs.ty.zigTypeTag() == .Int and rhs.ty.zigTypeTag() == .Int) {
            if (lhs.value()) |lhs_val| {
                if (rhs.value()) |rhs_val| {
                    // TODO is this a performance issue? maybe we should try the operation without
                    // resorting to BigInt first.
                    var lhs_space: Value.BigIntSpace = undefined;
                    var rhs_space: Value.BigIntSpace = undefined;
                    const lhs_bigint = lhs_val.toBigInt(&lhs_space);
                    const rhs_bigint = rhs_val.toBigInt(&rhs_space);
                    const limbs = try self.arena.allocator.alloc(
                        std.math.big.Limb,
                        std.math.max(lhs_bigint.limbs.len, rhs_bigint.limbs.len) + 1,
                    );
                    var result_bigint = BigIntMutable{ .limbs = limbs, .positive = undefined, .len = undefined };
                    result_bigint.add(lhs_bigint, rhs_bigint);
                    const result_limbs = result_bigint.limbs[0..result_bigint.len];

                    if (!lhs.ty.eql(rhs.ty)) {
                        return self.fail(scope, inst.base.src, "TODO implement peer type resolution", .{});
                    }

                    const val_payload = if (result_bigint.positive) blk: {
                        const val_payload = try self.arena.allocator.create(Value.Payload.IntBigPositive);
                        val_payload.* = .{ .limbs = result_limbs };
                        break :blk &val_payload.base;
                    } else blk: {
                        const val_payload = try self.arena.allocator.create(Value.Payload.IntBigNegative);
                        val_payload.* = .{ .limbs = result_limbs };
                        break :blk &val_payload.base;
                    };

                    return self.constInst(inst.base.src, .{
                        .ty = lhs.ty,
                        .val = Value.initPayload(val_payload),
                    });
                }
            }
        }

        return self.fail(scope, inst.base.src, "TODO implement more analyze add", .{});
    }

    fn analyzeInstDeref(self: *Module, scope: *Scope, deref: *text.Inst.Deref) InnerError!*Inst {
        const ptr = try self.resolveInst(scope, deref.positionals.ptr);
        const elem_ty = switch (ptr.ty.zigTypeTag()) {
            .Pointer => ptr.ty.elemType(),
            else => return self.fail(scope, deref.positionals.ptr.src, "expected pointer, found '{}'", .{ptr.ty}),
        };
        if (ptr.value()) |val| {
            return self.constInst(deref.base.src, .{
                .ty = elem_ty,
                .val = val.pointerDeref(),
            });
        }

        return self.fail(scope, deref.base.src, "TODO implement runtime deref", .{});
    }

    fn analyzeInstAsm(self: *Module, scope: *Scope, assembly: *text.Inst.Asm) InnerError!*Inst {
        const return_type = try self.resolveType(scope, assembly.positionals.return_type);
        const asm_source = try self.resolveConstString(scope, assembly.positionals.asm_source);
        const output = if (assembly.kw_args.output) |o| try self.resolveConstString(scope, o) else null;

        const inputs = try self.arena.allocator.alloc([]const u8, assembly.kw_args.inputs.len);
        const clobbers = try self.arena.allocator.alloc([]const u8, assembly.kw_args.clobbers.len);
        const args = try self.arena.allocator.alloc(*Inst, assembly.kw_args.args.len);

        for (inputs) |*elem, i| {
            elem.* = try self.resolveConstString(scope, assembly.kw_args.inputs[i]);
        }
        for (clobbers) |*elem, i| {
            elem.* = try self.resolveConstString(scope, assembly.kw_args.clobbers[i]);
        }
        for (args) |*elem, i| {
            const arg = try self.resolveInst(scope, assembly.kw_args.args[i]);
            elem.* = try self.coerce(scope, Type.initTag(.usize), arg);
        }

        const b = try self.requireRuntimeBlock(scope, assembly.base.src);
        return self.addNewInstArgs(b, assembly.base.src, return_type, Inst.Assembly, Inst.Args(Inst.Assembly){
            .asm_source = asm_source,
            .is_volatile = assembly.kw_args.@"volatile",
            .output = output,
            .inputs = inputs,
            .clobbers = clobbers,
            .args = args,
        });
    }

    fn analyzeInstCmp(self: *Module, scope: *Scope, inst: *text.Inst.Cmp) InnerError!*Inst {
        const lhs = try self.resolveInst(scope, inst.positionals.lhs);
        const rhs = try self.resolveInst(scope, inst.positionals.rhs);
        const op = inst.positionals.op;

        const is_equality_cmp = switch (op) {
            .eq, .neq => true,
            else => false,
        };
        const lhs_ty_tag = lhs.ty.zigTypeTag();
        const rhs_ty_tag = rhs.ty.zigTypeTag();
        if (is_equality_cmp and lhs_ty_tag == .Null and rhs_ty_tag == .Null) {
            // null == null, null != null
            return self.constBool(inst.base.src, op == .eq);
        } else if (is_equality_cmp and
            ((lhs_ty_tag == .Null and rhs_ty_tag == .Optional) or
            rhs_ty_tag == .Null and lhs_ty_tag == .Optional))
        {
            // comparing null with optionals
            const opt_operand = if (lhs_ty_tag == .Optional) lhs else rhs;
            if (opt_operand.value()) |opt_val| {
                const is_null = opt_val.isNull();
                return self.constBool(inst.base.src, if (op == .eq) is_null else !is_null);
            }
            const b = try self.requireRuntimeBlock(scope, inst.base.src);
            switch (op) {
                .eq => return self.addNewInstArgs(
                    b,
                    inst.base.src,
                    Type.initTag(.bool),
                    Inst.IsNull,
                    Inst.Args(Inst.IsNull){ .operand = opt_operand },
                ),
                .neq => return self.addNewInstArgs(
                    b,
                    inst.base.src,
                    Type.initTag(.bool),
                    Inst.IsNonNull,
                    Inst.Args(Inst.IsNonNull){ .operand = opt_operand },
                ),
                else => unreachable,
            }
        } else if (is_equality_cmp and
            ((lhs_ty_tag == .Null and rhs.ty.isCPtr()) or (rhs_ty_tag == .Null and lhs.ty.isCPtr())))
        {
            return self.fail(scope, inst.base.src, "TODO implement C pointer cmp", .{});
        } else if (lhs_ty_tag == .Null or rhs_ty_tag == .Null) {
            const non_null_type = if (lhs_ty_tag == .Null) rhs.ty else lhs.ty;
            return self.fail(scope, inst.base.src, "comparison of '{}' with null", .{non_null_type});
        } else if (is_equality_cmp and
            ((lhs_ty_tag == .EnumLiteral and rhs_ty_tag == .Union) or
            (rhs_ty_tag == .EnumLiteral and lhs_ty_tag == .Union)))
        {
            return self.fail(scope, inst.base.src, "TODO implement equality comparison between a union's tag value and an enum literal", .{});
        } else if (lhs_ty_tag == .ErrorSet and rhs_ty_tag == .ErrorSet) {
            if (!is_equality_cmp) {
                return self.fail(scope, inst.base.src, "{} operator not allowed for errors", .{@tagName(op)});
            }
            return self.fail(scope, inst.base.src, "TODO implement equality comparison between errors", .{});
        } else if (lhs.ty.isNumeric() and rhs.ty.isNumeric()) {
            // This operation allows any combination of integer and float types, regardless of the
            // signed-ness, comptime-ness, and bit-width. So peer type resolution is incorrect for
            // numeric types.
            return self.cmpNumeric(scope, inst.base.src, lhs, rhs, op);
        }
        return self.fail(scope, inst.base.src, "TODO implement more cmp analysis", .{});
    }

    fn analyzeInstIsNull(self: *Module, scope: *Scope, inst: *text.Inst.IsNull) InnerError!*Inst {
        const operand = try self.resolveInst(scope, inst.positionals.operand);
        return self.analyzeIsNull(scope, inst.base.src, operand, true);
    }

    fn analyzeInstIsNonNull(self: *Module, scope: *Scope, inst: *text.Inst.IsNonNull) InnerError!*Inst {
        const operand = try self.resolveInst(scope, inst.positionals.operand);
        return self.analyzeIsNull(scope, inst.base.src, operand, false);
    }

    fn analyzeInstCondBr(self: *Module, scope: *Scope, inst: *text.Inst.CondBr) InnerError!*Inst {
        const uncasted_cond = try self.resolveInst(scope, inst.positionals.condition);
        const cond = try self.coerce(scope, Type.initTag(.bool), uncasted_cond);

        if (try self.resolveDefinedValue(cond)) |cond_val| {
            const body = if (cond_val.toBool()) &inst.positionals.true_body else &inst.positionals.false_body;
            try self.analyzeBody(scope, body.*);
            return self.constVoid(inst.base.src);
        }

        const parent_block = try self.requireRuntimeBlock(scope, inst.base.src);

        var true_block: Scope.Block = .{
            .func = parent_block.func,
            .instructions = .{},
        };
        defer true_block.instructions.deinit();
        try self.analyzeBody(&true_block.base, inst.positionals.true_body);

        var false_block: Scope.Block = .{
            .func = parent_block.func,
            .instructions = .{},
        };
        defer false_block.instructions.deinit();
        try self.analyzeBody(&false_block.base, inst.positionals.false_body);

        // Copy the instruction pointers to the arena memory
        const true_instructions = try self.arena.allocator.alloc(*Inst, true_block.instructions.items.len);
        const false_instructions = try self.arena.allocator.alloc(*Inst, false_block.instructions.items.len);

        mem.copy(*Inst, true_instructions, true_block.instructions.items);
        mem.copy(*Inst, false_instructions, false_block.instructions.items);

        return self.addNewInstArgs(parent_block, inst.base.src, Type.initTag(.void), Inst.CondBr, Inst.Args(Inst.CondBr){
            .condition = cond,
            .true_body = .{ .instructions = true_instructions },
            .false_body = .{ .instructions = false_instructions },
        });
    }

    fn wantSafety(self: *Module, scope: *Scope) bool {
        return switch (self.optimize_mode) {
            .Debug => true,
            .ReleaseSafe => true,
            .ReleaseFast => false,
            .ReleaseSmall => false,
        };
    }

    fn analyzeInstUnreachable(self: *Module, scope: *Scope, unreach: *text.Inst.Unreachable) InnerError!*Inst {
        const b = try self.requireRuntimeBlock(scope, unreach.base.src);
        if (self.wantSafety(scope)) {
            // TODO Once we have a panic function to call, call it here instead of this.
            _ = try self.addNewInstArgs(b, unreach.base.src, Type.initTag(.void), Inst.Breakpoint, {});
        }
        return self.addNewInstArgs(b, unreach.base.src, Type.initTag(.noreturn), Inst.Unreach, {});
    }

    fn analyzeInstRet(self: *Module, scope: *Scope, inst: *text.Inst.Return) InnerError!*Inst {
        const b = try self.requireRuntimeBlock(scope, inst.base.src);
        return self.addNewInstArgs(b, inst.base.src, Type.initTag(.noreturn), Inst.Ret, {});
    }

    fn analyzeBody(self: *Module, scope: *Scope, body: text.Module.Body) !void {
        for (body.instructions) |src_inst| {
            const new_inst = self.analyzeInst(scope, src_inst) catch |err| {
                if (scope.cast(Scope.Block)) |b| {
                    self.fns.items[b.func.fn_index].analysis_status = .failure;
                    try b.func.inst_table.putNoClobber(src_inst, .{ .ptr = null });
                }
                return err;
            };
            if (scope.cast(Scope.Block)) |b| try b.func.inst_table.putNoClobber(src_inst, .{ .ptr = new_inst });
        }
    }

    fn analyzeIsNull(
        self: *Module,
        scope: *Scope,
        src: usize,
        operand: *Inst,
        invert_logic: bool,
    ) InnerError!*Inst {
        return self.fail(scope, src, "TODO implement analysis of isnull and isnotnull", .{});
    }

    /// Asserts that lhs and rhs types are both numeric.
    fn cmpNumeric(
        self: *Module,
        scope: *Scope,
        src: usize,
        lhs: *Inst,
        rhs: *Inst,
        op: std.math.CompareOperator,
    ) !*Inst {
        assert(lhs.ty.isNumeric());
        assert(rhs.ty.isNumeric());

        const lhs_ty_tag = lhs.ty.zigTypeTag();
        const rhs_ty_tag = rhs.ty.zigTypeTag();

        if (lhs_ty_tag == .Vector and rhs_ty_tag == .Vector) {
            if (lhs.ty.arrayLen() != rhs.ty.arrayLen()) {
                return self.fail(scope, src, "vector length mismatch: {} and {}", .{
                    lhs.ty.arrayLen(),
                    rhs.ty.arrayLen(),
                });
            }
            return self.fail(scope, src, "TODO implement support for vectors in cmpNumeric", .{});
        } else if (lhs_ty_tag == .Vector or rhs_ty_tag == .Vector) {
            return self.fail(scope, src, "mixed scalar and vector operands to comparison operator: '{}' and '{}'", .{
                lhs.ty,
                rhs.ty,
            });
        }

        if (lhs.value()) |lhs_val| {
            if (rhs.value()) |rhs_val| {
                return self.constBool(src, Value.compare(lhs_val, op, rhs_val));
            }
        }

        // TODO handle comparisons against lazy zero values
        // Some values can be compared against zero without being runtime known or without forcing
        // a full resolution of their value, for example `@sizeOf(@Frame(function))` is known to
        // always be nonzero, and we benefit from not forcing the full evaluation and stack frame layout
        // of this function if we don't need to.

        // It must be a runtime comparison.
        const b = try self.requireRuntimeBlock(scope, src);
        // For floats, emit a float comparison instruction.
        const lhs_is_float = switch (lhs_ty_tag) {
            .Float, .ComptimeFloat => true,
            else => false,
        };
        const rhs_is_float = switch (rhs_ty_tag) {
            .Float, .ComptimeFloat => true,
            else => false,
        };
        if (lhs_is_float and rhs_is_float) {
            // Implicit cast the smaller one to the larger one.
            const dest_type = x: {
                if (lhs_ty_tag == .ComptimeFloat) {
                    break :x rhs.ty;
                } else if (rhs_ty_tag == .ComptimeFloat) {
                    break :x lhs.ty;
                }
                if (lhs.ty.floatBits(self.target()) >= rhs.ty.floatBits(self.target())) {
                    break :x lhs.ty;
                } else {
                    break :x rhs.ty;
                }
            };
            const casted_lhs = try self.coerce(scope, dest_type, lhs);
            const casted_rhs = try self.coerce(scope, dest_type, rhs);
            return self.addNewInstArgs(b, src, dest_type, Inst.Cmp, Inst.Args(Inst.Cmp){
                .lhs = casted_lhs,
                .rhs = casted_rhs,
                .op = op,
            });
        }
        // For mixed unsigned integer sizes, implicit cast both operands to the larger integer.
        // For mixed signed and unsigned integers, implicit cast both operands to a signed
        // integer with + 1 bit.
        // For mixed floats and integers, extract the integer part from the float, cast that to
        // a signed integer with mantissa bits + 1, and if there was any non-integral part of the float,
        // add/subtract 1.
        const lhs_is_signed = if (lhs.value()) |lhs_val|
            lhs_val.compareWithZero(.lt)
        else
            (lhs.ty.isFloat() or lhs.ty.isSignedInt());
        const rhs_is_signed = if (rhs.value()) |rhs_val|
            rhs_val.compareWithZero(.lt)
        else
            (rhs.ty.isFloat() or rhs.ty.isSignedInt());
        const dest_int_is_signed = lhs_is_signed or rhs_is_signed;

        var dest_float_type: ?Type = null;

        var lhs_bits: usize = undefined;
        if (lhs.value()) |lhs_val| {
            if (lhs_val.isUndef())
                return self.constUndef(src, Type.initTag(.bool));
            const is_unsigned = if (lhs_is_float) x: {
                var bigint_space: Value.BigIntSpace = undefined;
                var bigint = try lhs_val.toBigInt(&bigint_space).toManaged(self.allocator);
                defer bigint.deinit();
                const zcmp = lhs_val.orderAgainstZero();
                if (lhs_val.floatHasFraction()) {
                    switch (op) {
                        .eq => return self.constBool(src, false),
                        .neq => return self.constBool(src, true),
                        else => {},
                    }
                    if (zcmp == .lt) {
                        try bigint.addScalar(bigint.toConst(), -1);
                    } else {
                        try bigint.addScalar(bigint.toConst(), 1);
                    }
                }
                lhs_bits = bigint.toConst().bitCountTwosComp();
                break :x (zcmp != .lt);
            } else x: {
                lhs_bits = lhs_val.intBitCountTwosComp();
                break :x (lhs_val.orderAgainstZero() != .lt);
            };
            lhs_bits += @boolToInt(is_unsigned and dest_int_is_signed);
        } else if (lhs_is_float) {
            dest_float_type = lhs.ty;
        } else {
            const int_info = lhs.ty.intInfo(self.target());
            lhs_bits = int_info.bits + @boolToInt(!int_info.signed and dest_int_is_signed);
        }

        var rhs_bits: usize = undefined;
        if (rhs.value()) |rhs_val| {
            if (rhs_val.isUndef())
                return self.constUndef(src, Type.initTag(.bool));
            const is_unsigned = if (rhs_is_float) x: {
                var bigint_space: Value.BigIntSpace = undefined;
                var bigint = try rhs_val.toBigInt(&bigint_space).toManaged(self.allocator);
                defer bigint.deinit();
                const zcmp = rhs_val.orderAgainstZero();
                if (rhs_val.floatHasFraction()) {
                    switch (op) {
                        .eq => return self.constBool(src, false),
                        .neq => return self.constBool(src, true),
                        else => {},
                    }
                    if (zcmp == .lt) {
                        try bigint.addScalar(bigint.toConst(), -1);
                    } else {
                        try bigint.addScalar(bigint.toConst(), 1);
                    }
                }
                rhs_bits = bigint.toConst().bitCountTwosComp();
                break :x (zcmp != .lt);
            } else x: {
                rhs_bits = rhs_val.intBitCountTwosComp();
                break :x (rhs_val.orderAgainstZero() != .lt);
            };
            rhs_bits += @boolToInt(is_unsigned and dest_int_is_signed);
        } else if (rhs_is_float) {
            dest_float_type = rhs.ty;
        } else {
            const int_info = rhs.ty.intInfo(self.target());
            rhs_bits = int_info.bits + @boolToInt(!int_info.signed and dest_int_is_signed);
        }

        const dest_type = if (dest_float_type) |ft| ft else blk: {
            const max_bits = std.math.max(lhs_bits, rhs_bits);
            const casted_bits = std.math.cast(u16, max_bits) catch |err| switch (err) {
                error.Overflow => return self.fail(scope, src, "{} exceeds maximum integer bit count", .{max_bits}),
            };
            break :blk try self.makeIntType(dest_int_is_signed, casted_bits);
        };
        const casted_lhs = try self.coerce(scope, dest_type, lhs);
        const casted_rhs = try self.coerce(scope, dest_type, lhs);

        return self.addNewInstArgs(b, src, dest_type, Inst.Cmp, Inst.Args(Inst.Cmp){
            .lhs = casted_lhs,
            .rhs = casted_rhs,
            .op = op,
        });
    }

    fn makeIntType(self: *Module, signed: bool, bits: u16) !Type {
        if (signed) {
            const int_payload = try self.arena.allocator.create(Type.Payload.IntSigned);
            int_payload.* = .{ .bits = bits };
            return Type.initPayload(&int_payload.base);
        } else {
            const int_payload = try self.arena.allocator.create(Type.Payload.IntUnsigned);
            int_payload.* = .{ .bits = bits };
            return Type.initPayload(&int_payload.base);
        }
    }

    fn coerce(self: *Module, scope: *Scope, dest_type: Type, inst: *Inst) !*Inst {
        // If the types are the same, we can return the operand.
        if (dest_type.eql(inst.ty))
            return inst;

        const in_memory_result = coerceInMemoryAllowed(dest_type, inst.ty);
        if (in_memory_result == .ok) {
            return self.bitcast(scope, dest_type, inst);
        }

        // *[N]T to []T
        if (inst.ty.isSinglePointer() and dest_type.isSlice() and
            (!inst.ty.pointerIsConst() or dest_type.pointerIsConst()))
        {
            const array_type = inst.ty.elemType();
            const dst_elem_type = dest_type.elemType();
            if (array_type.zigTypeTag() == .Array and
                coerceInMemoryAllowed(dst_elem_type, array_type.elemType()) == .ok)
            {
                return self.coerceArrayPtrToSlice(dest_type, inst);
            }
        }

        // comptime_int to fixed-width integer
        if (inst.ty.zigTypeTag() == .ComptimeInt and dest_type.zigTypeTag() == .Int) {
            // The representation is already correct; we only need to make sure it fits in the destination type.
            const val = inst.value().?; // comptime_int always has comptime known value
            if (!val.intFitsInType(dest_type, self.target())) {
                return self.fail(scope, inst.src, "type {} cannot represent integer value {}", .{ inst.ty, val });
            }
            return self.constInst(inst.src, .{ .ty = dest_type, .val = val });
        }

        // integer widening
        if (inst.ty.zigTypeTag() == .Int and dest_type.zigTypeTag() == .Int) {
            const src_info = inst.ty.intInfo(self.target());
            const dst_info = dest_type.intInfo(self.target());
            if (src_info.signed == dst_info.signed and dst_info.bits >= src_info.bits) {
                if (inst.value()) |val| {
                    return self.constInst(inst.src, .{ .ty = dest_type, .val = val });
                } else {
                    return self.fail(scope, inst.src, "TODO implement runtime integer widening", .{});
                }
            } else {
                return self.fail(scope, inst.src, "TODO implement more int widening {} to {}", .{ inst.ty, dest_type });
            }
        }

        return self.fail(scope, inst.src, "TODO implement type coercion from {} to {}", .{ inst.ty, dest_type });
    }

    fn bitcast(self: *Module, scope: *Scope, dest_type: Type, inst: *Inst) !*Inst {
        if (inst.value()) |val| {
            // Keep the comptime Value representation; take the new type.
            return self.constInst(inst.src, .{ .ty = dest_type, .val = val });
        }
        // TODO validate the type size and other compile errors
        const b = try self.requireRuntimeBlock(scope, inst.src);
        return self.addNewInstArgs(b, inst.src, dest_type, Inst.BitCast, Inst.Args(Inst.BitCast){ .operand = inst });
    }

    fn coerceArrayPtrToSlice(self: *Module, dest_type: Type, inst: *Inst) !*Inst {
        if (inst.value()) |val| {
            // The comptime Value representation is compatible with both types.
            return self.constInst(inst.src, .{ .ty = dest_type, .val = val });
        }
        return self.fail(scope, inst.src, "TODO implement coerceArrayPtrToSlice runtime instruction", .{});
    }

    fn fail(self: *Module, scope: *Scope, src: usize, comptime format: []const u8, args: var) InnerError {
        @setCold(true);
        const err_msg = ErrorMsg{
            .byte_offset = src,
            .msg = try std.fmt.allocPrint(self.allocator, format, args),
        };
        if (scope.cast(Scope.Block)) |block| {
            block.func.analysis = .{ .failure = err_msg };
        } else if (scope.cast(Scope.Decl)) |scope_decl| {
            scope_decl.decl.analysis = .{ .failure = err_msg };
        } else {
            unreachable;
        }
        return error.AnalysisFail;
    }

    const InMemoryCoercionResult = enum {
        ok,
        no_match,
    };

    fn coerceInMemoryAllowed(dest_type: Type, src_type: Type) InMemoryCoercionResult {
        if (dest_type.eql(src_type))
            return .ok;

        // TODO: implement more of this function

        return .no_match;
    }
};

pub const ErrorMsg = struct {
    byte_offset: usize,
    msg: []const u8,

    pub fn create(allocator: *Allocator, byte_offset: usize, comptime format: []const u8, args: var) !*ErrorMsg {
        const self = try allocator.create(ErrorMsg);
        errdefer allocator.destroy(ErrorMsg);
        self.* = init(allocator, byte_offset, format, args);
        return self;
    }

    /// Assumes the ErrorMsg struct and msg were both allocated with allocator.
    pub fn destroy(self: *ErrorMsg, allocator: *Allocator) void {
        self.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn init(allocator: *Allocator, byte_offset: usize, comptime format: []const u8, args: var) !ErrorMsg {
        return ErrorMsg{
            .byte_offset = byte_offset,
            .msg = try std.fmt.allocPrint(allocator, format, args),
        };
    }

    pub fn deinit(self: *ErrorMsg, allocator: *Allocator) void {
        allocator.free(err_msg.msg);
        self.* = undefined;
    }
};

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = if (std.builtin.link_libc) std.heap.c_allocator else &arena.allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const src_path = args[1];
    const bin_path = args[2];
    const debug_error_trace = true;
    const output_zir = true;

    const native_info = try std.zig.system.NativeTargetInfo.detect(allocator, .{});

    var bin_file = try link.openBinFilePath(allocator, std.fs.cwd(), bin_path, .{
        .target = native_info.target,
        .output_mode = .Exe,
        .link_mode = .Static,
        .object_format = options.object_format orelse native_info.target.getObjectFormat(),
    });
    defer bin_file.deinit(allocator);

    var module = blk: {
        const root_pkg = try Package.create(allocator, std.fs.cwd(), ".", src_path);
        errdefer root_pkg.destroy();

        const root_scope = try allocator.create(Module.Scope.ZIRModule);
        errdefer allocator.destroy(root_scope);
        root_scope.* = .{
            .sub_file_path = root_pkg.root_src_path,
            .contents = .unloaded,
        };

        break :blk Module{
            .allocator = allocator,
            .root_pkg = root_pkg,
            .root_scope = root_scope,
            .bin_file = &bin_file,
            .optimize_mode = .Debug,
            .decl_table = std.AutoHashMap(Decl.Hash, *Decl).init(allocator),
        };
    };
    defer module.deinit();

    try module.update();

    const errors = try module.getAllErrorsAlloc();
    defer errors.deinit();

    if (errors.list.len != 0) {
        for (errors.list) |full_err_msg| {
            std.debug.warn("{}:{}:{}: error: {}\n", .{
                full_err_msg.src_path,
                full_err_msg.line + 1,
                full_err_msg.column + 1,
                full_err_msg.msg,
            });
        }
        if (debug_error_trace) return error.AnalysisFail;
        std.process.exit(1);
    }

    if (output_zir) {
        var new_zir_module = try text.emit_zir(allocator, module);
        defer new_zir_module.deinit(allocator);

        var bos = std.io.bufferedOutStream(std.io.getStdOut().outStream());
        try new_zir_module.writeToStream(allocator, bos.outStream());
        try bos.flush();
    }
}

// Performance optimization ideas:
// * when analyzing use a field in the Inst instead of HashMap to track corresponding instructions
