class Sass::Tree::Visitors::ToRuby < Sass::Tree::Visitors::Base
  class << self
    def visit(root, options)
      new(options).send(:visit, root)
    end
  end

  def initialize(options)
    @imports = {}
    @importer_vars = Sass::Util.to_hash(
      Sass::Util.enum_with_index(options[:load_paths]).map do |(importer, i)|
        [importer, "@_s_importer_0#{i}"]
      end)
  end

  def visit_children(parent)
    # Make sure the environment knows about all definitions defined at this
    # scope. That way nested references to those definitions will refer to the
    # correct referents.
    parent.children.each do |child|
      case child
      when Sass::Tree::VariableNode
        @environment.declare_var(child.name) unless child.global
      when Sass::Tree::FunctionNode
        @environment.declare_fn(child.name, child)
      end
    end

    super.join("\n")
  end

  def with_parent(name)
    old_env, @environment = @environment, Sass::Environment.new(@environment)
    old_parent_var, @parent_var = @parent_var, name
    old_env_var = @environment.unique_ident(:old_env)
    "#{old_env_var}, _s_env = _s_env, ::Sass::Environment.new(_s_env)\n" +
      yield + "\n" +
      "_s_env = #{old_env_var}"
  ensure
    @parent_var = old_parent_var
    @environment = old_env
  end

  def with_environment(environment)
    old_env, @environment = @environment, environment
    yield
  ensure
    @environment = old_env
  end

  def visit_root(node)
    @importer_vars.map do |(importer, ident)|
      "#{ident} = Marshal.load(#{Marshal.dump(importer).dump})\n"
    end.join + "_s_env = ::Sass::Environment.new\n" +
      "_s_importer = #{@importer_vars[node.options[:importer]]}\n" +
      "_s_root = ::Sass::Tree::RootNode.new('')\n" +
      with_parent("_s_root") {yield} + "\n_s_root"
  end

  def visit_comment(node)
    return '' if node.invisible?
    "#{@parent_var} << ::Sass::Tree::CommentNode.resolved(" +
      "#{interp_no_strip(node.value)}, #{node.type.inspect}, #{node.source_range.to_ruby})"
  end

  def visit_for(node)
    with_environment Sass::SemiGlobalEnvironment.new(@environment) do
      from_var = @environment.unique_ident(:from)
      to_var = @environment.unique_ident(:to)
      direction_var = @environment.unique_ident(:direction)
      iter_var = @environment.declare_var(node.var)

      # TODO: This is ripe for optimization. If from and to are static integers,
      # we can generate much simpler code.
      ruby = <<RUBY
#{from_var} = #{node.from.to_ruby(@environment)}
#{to_var} = #{node.to.to_ruby(@environment)}
#{from_var}.assert_int!
#{to_var}.assert_int!
#{to_var} = #{to_var}.coerce(#{from_var}.numerator_units, #{from_var}.denominator_units)
#{direction_var} = (#{from_var}.to_i > #{to_var}.to_i ? -1 : 1)
Range.new(#{direction_var} * #{from_var}.to_i, #{direction_var} * #{to_var}.to_i, #{node.exclusive}).
    each do |#{iter_var}|
  #{iter_var} = Sass::Script::Value::Number.new(#{direction_var} * #{iter_var},
    #{from_var}.numerator_units, #{from_var}.denominator_units)
RUBY

      ruby << node.children.map {|c| visit(c)}.join("\n") << "\nend"
    end
  end

  def visit_function(node)
    name = @environment.declare_fn(node.name, node)
    with_parent(nil) do
      ruby = "#{name} = lambda do |" + node.args.map do |(arg, default)|
        arg_name = @environment.declare_var(arg.name)
        next arg_name unless default
        "#{arg_name} = nil"
      end.join(', ')

      if node.splat
        ruby << ', ' unless node.args.empty?
        splat_arg = @environment.declare_var(node.splat.name)
        ruby << "*#{splat_arg}"
      end

      # TODO: support splat and named args
      ruby << "|\n"

      node.args.each do |(arg, default)|
        next unless default
        ruby << "#{@environment.var_variable(arg.name)} ||= #{default.to_ruby(@environment)}\n"
      end

      ruby << "#{splat_arg} = Sass::Script::Value::ArgList.new(#{splat_arg})\n" if node.splat
      ruby << yield << "\nend"
    end
  end

  def visit_import(node)
    if (path = node.css_import?)
      return "#{@parent_var} << ::Sass::Tree::CssImportNode.resolved(#{"url(#{path})".dump}, " +
        "#{node.source_range.to_ruby})"
    end

    # TODO: Handle import loops.
    # Longer-term TODO: Under --watch, only re-eval these methods when the files
    # change.
    file = node.imported_file
    filename = file.options[:filename]
    ruby = ''
    unless (method_name = @imports[filename])
      method_name = @imports[filename] = @environment.unique_ident("import_#{filename}")
      root = file.to_tree
      Sass::Tree::Visitors::CheckNesting.visit(root)
      ruby = "def #{method_name}(#{@parent_var}, _s_env)\n" +
        "_s_importer = #{@importer_vars[file.options[:importer]]}\n" +
        root.children.map {|c| visit(c)}.join("\n") + "\nend\n"
    end

    ruby + "#{method_name}(#{@parent_var}, _s_env)"
  end

  def visit_prop(node)
    prop_var = @environment.unique_ident(:prop)
    ruby = "#{@parent_var} << #{prop_var} = ::Sass::Tree::PropNode.resolved(#{interp(node.name)}, " +
      "#{node.value.to_ruby(@environment)}.to_s, #{node.source_range.to_ruby}, " +
      "#{node.name_source_range.to_ruby}, #{node.value_source_range.to_ruby})"
    with_parent(prop_var) {ruby + yield}
  end

  def visit_return(node)
    "return #{node.expr.to_ruby(@environment)}"
  end

  def visit_rule(node)
    parser_var = @environment.unique_ident(:parser)
    selector_var = @environment.unique_ident(:selector)
    ruby = "#{parser_var} = ::Sass::SCSS::StaticParser.new(#{interp(node.rule)}, '', nil, 0)\n"
    rule_var = @environment.unique_ident(:rule)
    ruby << "#{@parent_var} << #{rule_var} = ::Sass::Tree::RuleNode.resolved(" +
      "#{parser_var}.parse_selector.resolve_parent_refs(_s_env.selector), " +
      "#{node.source_range.to_ruby}, #{node.selector_source_range.to_ruby})\n"
    with_parent(rule_var) do
      ruby << "_s_env.selector = #{rule_var}.resolved_rules\n"
      ruby + yield
    end
  end

  def visit_variable(node)
    old_var_var = @environment.var_variable(node.name)
    var_var = old_var_var ||
      if node.global
        @environment.declare_global_var(node.name)
      else
        @environment.declare_var(node.name)
      end

    ruby = "#{var_var} = #{node.expr.to_ruby(@environment)}"
    ruby << "if #{var_var}.null?" if node.guarded && old_var_var
    ruby
  end

  def interp(script)
    script.map do |e|
      next e.dump if e.is_a?(String)
      "#{e.to_ruby(@environment)}.to_s"
    end.join(" + ")
  end
end
