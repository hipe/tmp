#!/usr/bin/env ruby -w
require 'optparse'
require 'pp'
require 'strscan'
require 'rubygems'
# require 'ruby-debug'; $stderr.puts "\e[1;5;33mruby-debug\e[0m"
require 'treetop'

module Hipe
  module ConvoGrammar
    VERSION = '0.0.0'
  end
end

module Hipe::ConvoGrammar
  class CliBase
    def run argv
      @c = build_execution_context
      @argv = argv
      @queue = []
      @exit_ok = false
      begin
        option_parser.parse!(@argv)
      rescue ::OptionParser::InvalidOption => e
        usage e.message
        return
      end
      @queue.empty? and @queue.push(default_action)
      @queue.each{ |m| send(m) }
    end
  protected
    def fatal msg
      @c.err.puts msg
      exit(1)
    end
    def help_string
      option_parser.to_s
    end
    def on_help
      @exit_ok = true
      @c.err.puts help_string
    end
    def option_parser
      @option_parser ||= build_option_parser
    end
    def program_name
      File.basename($PROGRAM_NAME)
    end
    def usage msg
      @c.err.puts msg
      @c.err.puts help_string
      nil
    end
  end

  module HashBooleanAttrAccessor
    def boolean_attr_accessor yes, no=nil
      no ||= "no_#{yes}"
      define_method("#{yes}!"){ self[yes] = true }
      define_method("#{no}!"){ self[yes] = false }
      define_method("#{yes}?"){ self[yes] }
      define_method("#{no}?"){ ! self[yes] }
    end
  end

  class ExecutionContext < Hash
    extend HashBooleanAttrAccessor

    def initialize ins=nil, out=nil, err=nil
      @in = ins; @out = out; @err = err
      @builder = TreetopBuilder.new(self)
    end
    attr_reader :builder
    attr_accessor :in, :out, :err
    boolean_attr_accessor :case_insensitive, :case_sensitive
    boolean_attr_accessor :show_sexp, :dont_show_sexp
    boolean_attr_accessor :progressive_output

    def reverse_merge! *h
      h.each{ |h0| replace(h0.merge(self)) }
      self
    end

    def singleton_class
      @sc ||= class << self; self end
    end
    ### abstractable above
    def flex_name_to_rule_name flex_name
      flex_name # @todo prefixes, whatever
    end
  end

  # we keep these outside of the constructor for reasons
  ExecutionContextDefaults = {
    :case_sensitive     => true,
    :show_sexp          => false,
    :progressive_output => true
  }

  class Cli < CliBase
    def build_option_parser
      o = OptionParser.new
      o.banner = "Usage: #{program_name} [options] <flexfile>"

      o.on('-g=<grammar>', '--grammar=<grammar>',
      "Also output grammar declaration (or \"Mod1::Mod2::Grammar\")"
      ) { |g| @c[:grammar] = g }

      o.on('-s', '--sexp',
        "(development) Show sexp of parsed flex file and exit"
      ) { @c.show_sexp! }

      o.on('--flex-tt',
       '(development) Write the flex treetop grammar to stdout.'
      ) { @queue.push :on_grammar }

      o.on('-t[=<dir>]', '--tempdir[=<dir>]',
        '(development) Write/Read flex treetop grammar ' <<
          'from/to the filesystem.'
      ) { |d| @c[:use_parser_dir] = d; @no_file_ok = true }

      o.on('-c', '--clear',
        "(development) If using --tempdir, clear existing files first."
      ) { @c[:clear_generated_files] = true }

      o.on('-h', '--help', 'Show this message') { @queue.push :on_help }
      o.on('-v', '--version', 'Show Version') { @queue.push :on_version }
      o
    end

    def build_execution_context
      ExecutionContext.new($stdin, $stdout, $stderr).
        reverse_merge!(ExecutionContextDefaults)
    end

    def default_action; :run_translate end

    def on_grammar
      @exit_ok = true
      @c.out.puts TreetopGrammar
    end

    def on_version
      @exit_ok = true
      @c.err.puts "#{program_name} version #{VERSION}"
    end

    def run_translate
      resolve_input or return
      @c.builder.progressive_output! if @c.progressive_output?
      Translator.new(@c).run
    end

    def resolve_input
      if @c.in.tty?
        @c.in = nil
        if @exit_ok and @argv.empty?
          @c.err.puts 'No file arguments present.  Done.'
        elsif @argv.size != 1
          if @no_file_ok && @argv.size == 0
            true
          else
            usage "expecting: <flexfile> had: (#{@argv.join(' ')})"
          end
        elsif ! File.exist?(infile = @argv.shift)
          usage "<flexfile> not found: #{infile}"
        else
          @c.in = File.open(infile, 'r')
        end
      else
        if @argv.size != 0
          usage("reading STDIN as <flexfile>, had: (#{argv.join(' ')})")
        else
          true # leave @c.in as $stdin
        end
      end
    end
  end

  class Translator
    def initialize ctx=nil
      @c = if ctx.nil?
        ExecutionContext.new($stdin, $stdout, $stderr).
          reverse_merge!(ExecutionContextDefaults)
      elsif ctx.kind_of?(ExecutionContext)
        ctx
      elsif ctx.kind_of?(Hash)
        ec = ExecutionContext.new.reverse_merge!(
          ctx, ExecutionContextDefaults)
        [:in, :out, :err].each do |m|
          ctx.respond_to?(m) and ec.send("#{m}=", ctx.send(m))
        end
        ec
      else
        ctx # whatever no never dumb
      end
    end
    def execution_context; @c end
    def run
      @exit_ok = false
      @c.key?(:use_parser_dir) and (use_parser_dir or return)
      ! @c.in and @exit_ok and return
      p = parser
      whole_file = @c.in.read
      @c.in.close
      resp = p.parse(whole_file)
      if resp.nil?
        rsn = p.failure_reason || "Got nil from parse without reason!"
        @c.err.puts rsn
      elsif true # @c.show_sexp?
        PP.pp(resp, @c.err)
        # PP.pp(resp.sexp, @c.err)
      else
        # resp.sexp.translate @c
      end
    end
    TranslateDefaults = { :verbose => true, :force => false, :grammar => nil }
    def translate flex_path, output_grammar_path, opts={}
      o = merge_opts(opts, @c, TranslateDefaults)
      o[:grammar] and @c[:grammar] = o[:grammar]
      if File.exist?(output_grammar_path)
        unless o[:force]
          @c.err.puts "using: #{shortpath(output_grammar_path)}."
          return :exists
        end
        s = nil; File.open(output_grammar_path, 'r'){ |fh| s = fh.gets }
        if (! s.nil? && s.chomp != autogenerated_line.chomp)
          raise RuntimeError.new(
            "won't overwrite file without augenerated line!")
        end
        verb = 'regenerating'
      else
        verb = 'creating'
      end
      o[:verbose] and @c.err.puts "#{verb} " <<
        "#{shortpath(output_grammar_path)} with "<<
          "#{shortpath(flex_path)}"
      @c.in = File.open(flex_path, 'r')
      @c.out = File.open(output_grammar_path, 'w')
      @c.builder.progressive_output!
      @c.out.puts autogenerated_line
      ret = nil
      begin
        ret = run
      ensure
        @c.in.closed? or @c.in.close
        @c.out.closed? or @c.out.close
      end
      ret
    end
  private
    def autogenerated_line
      '# Autogenerated by flex-to-treetop.  Edits may be lost.'
    end
    def clear_generated_files
      [@gpath, @ppath].each do |path|
        File.exist?(path) and file_utils.rm(path, :verbose => true)
      end
    end
    def file_utils
      @file_utils ||= begin
        require 'fileutils'
        o = Object.new
        class << o
          include FileUtils
          public :rm
        end
        o.instance_variable_set('@fileutils_output', @c.err)
        o
      end
    end
    # given an array of hashes
    # @return a new hash with only the keys of the last hash and the values
    # of the first hash found with that key
    def merge_opts *ox
      defaults = ox.last
      Hash[ defaults.keys.map do |k|
        [ k, ox.detect{ |h| h.key?(k) }[k] ]
      end ]
    end
    def parser
      @parser ||= parser_class.new
    end
    def parser_class
      @parser_class ||= begin
        if ! Hipe::ConvoGrammar.const_defined?(:FooParser)
          ::Treetop.load_from_string Hipe::ConvoGrammar::TreetopGrammar
        end
        c = Class.new FooParser
        c.class_eval(&ParserExtlib)
        c
      end
    end
    def shortpath path
      @c.key?(:root) or return path
      @rootre ||= %r{\A#{Regexp.escape(@c[:root])}/?}
      path.sub(@rootre, '')
    end
    def write_grammar_file
      @exit_ok = true
      b = nil
      File.open(@gpath, 'w+'){ |fh| b = fh.write(TreetopGrammar) }
      b
    end
    def use_parser_dir
      dir = (@c[:use_parser_dir] != "") ? @c[:use_parser_dir] : begin
        require 'tmpdir'
        Dir.tmpdir
      end
      File.directory?(dir) or raise RuntimeError.new("not a dir: #{dir}")
      @gpath = File.join(dir, 'flex-to-treetop.treetop')
      @ppath = File.join(dir, 'flex-to-treetop.rb')
      @c[:clear_generated_files] and clear_generated_files
      if File.exist?(@ppath)
        @c.err.puts "using: #{@ppath}"
      else
        recompile
      end
      require @ppath
    end
    def recompile
      @exit_ok = true
      s = []
      File.exist?(@gpath) or begin
        b = write_grammar_file
        s.push "wrote #{@gpath} (#{b} bytes)."
      end
      s.push "writing #{@ppath}."
      @c.err.puts s.join(' ')
      begin
        Treetop::Compiler::GrammarCompiler.new.compile(@gpath, @ppath)
      rescue ::RuntimeError => e
        raise RuntimeError.new(e.message)
      end
    end
  end
end

class Hipe::ConvoGrammar::Sexpesque < Array # class Sexpesque
  class << self
    def add_hook(whenn, &what)
      @hooks ||= Hash.new{ |h,k| h[k] = [] }
      @hooks[whenn].push(what)
    end
    def guess_node_name
      m = to_s.match(/([^:]+)Sexp$/) and
        m[1].gsub(/([a-z])([A-Z])/){ "#{$1}_#{$2}" }.downcase.intern
    end
    def hooks_for(whenn)
      instance_variable_defined?('@hooks') ? @hooks[whenn] : []
    end
    def from_syntax_node name, node
      new(name, node).extend SyntaxNodeHaver
    end
    def traditional name, *rest
      new(name, *rest)
    end
    def hashy name, hash
      new(name, hash).extend Hashy
    end
    attr_writer :node_name
    def node_name *a
      a.any? ? (@node_name = a.first) :
      (instance_variable_defined?('@node_name') ? @node_name :
        (@node_name = guess_node_name))
    end
    def list list
      traditional(node_name, *list)
    end
    def terminal!
      add_hook(:post_init){ |me| me.stringify_terminal_syntax_node! }
    end
  end
  def initialize name, *rest
    super [name, *rest]
    self.class.hooks_for(:post_init).each{ |h| h.call(self) }
  end
  def stringify_terminal_syntax_node!
    self[1] = self[1].text_value
    @syntax_node = nil
    class << self
      alias_method :my_text_value, :last
    end
  end
  module SyntaxNodeHaver
    def syntax_node
      instance_variable_defined?('@syntax_node') ? @syntax_node : last
    end
  end
  module Hashy
    class << self
      def extended obj
        class << obj
          alias_method :children, :last
        end
      end
    end
  end
end

module Hipe::ConvoGrammar::CommonNodey
  Sexpesque = ::Hipe::ConvoGrammar::Sexpesque
  def at(str); ats(str).first end
  def ats path
    path = at_compile(path) if path.kind_of?(String)
    here = path.first
    cx = (here == '*') ? elements : (elements[here] ? [elements[here]] : [])
    if path.size > 1 && cx.any?
      child_path = path[1..-1]
      cx = cx.map do |c|
        c.extend(::Hipe::ConvoGrammar::CommonNodey) unless
          c.respond_to?(:ats)
        c.ats(child_path)
      end.flatten
    end
    cx
  end
  def at_compile str
    res = []
    s = StringScanner.new(str)
    begin
      if s.scan(/\*/)
        res.push '*'
      elsif s.scan(/\[/)
        d = s.scan(/\d+/) or fail("expecting digit had #{s.rest.inspect}")
        s.scan(/\]/) or fail("expecting ']' had #{s.rest.inspect}")
        res.push d.to_i
      else
        fail("expecting '*' or '[' near #{s.rest.inspect}")
      end
    end until s.eos?
    res
  end
  def sexp_at str
    # (n = at(str)) ? n.sexp : nil
    n = at(str) or return nil
    n.respond_to?(:sexp) and return n.sexp
    n.text_value == '' and return nil
    fail("where is sexp for n")
  end
  def sexps_at str
    ats(str).map(&:sexp)
  end
  def composite_sexp my_name, *children
    with_names = {}
    children.each do |name|
      got = send(name)
      sexp =
        if got.respond_to?(:sexp)
          got.sexp
        else
          fail('why does "got" have no sexp')
        end
      with_names[name] = sexp
    end
    if my_name.kind_of? Class
      my_name.hashy(my_name.node_name, with_names)
    else
      Sexpesque.hashy(my_name, with_names)
    end
  end
  def list_sexp *foos
    foos.compact!
    foos # yeah, that's all this does
  end
  def auto_sexp
    if respond_to?(:sexp_class)
      sexp_class.from_syntax_node(sexp_class.node_name, self)
    elsif ! elements.nil? && elements.index{ |n| n.respond_to?(:sexp) }
      cx = elements.map{ |n| n.respond_to?(:sexp) ? n.sexp : n.text_value }
      ::Hipe::ConvoGrammar::AutoSexp.traditional(guess_node_name, *cx)
    else
      ::Hipe::ConvoGrammar::AutoSexp.traditional(guess_node_name, text_value)
    end
  end
  def guess_node_name
    m = singleton_class.ancestors.first.to_s.match(/([^:0-9]+)\d+$/)
    if m
      m[1].gsub(/([a-z])([A-Z])/){ "#{$1}_#{$2}" }.downcase.intern
    else
      fail("what happen")
    end
  end
  def singleton_class
    @sc ||= class << self; self end
  end
end

module Hipe::ConvoGrammar
  class CommonNode < ::Treetop::Runtime::SyntaxNode
    include CommonNodey
  end
  module AutoNodey
    include CommonNodey
    def sexp; auto_sexp end
  end
  class AutoNode < CommonNode
    include AutoNodey
  end
end

module Hipe::ConvoGrammar
  class RuleBuilder
    def initialize ctx
      @ctx = ctx
      @builder = ctx.builder
    end
    attr_accessor :rule_name
    attr_accessor :pattern_like
    def write
      @builder.rule_declaration(@ctx.flex_name_to_rule_name(rule_name)) do
        @builder.write "".indent(@builder.level)
        pattern_like.translate(@ctx)
        @builder.newline
      end
    end
  end
  module RuleWriter
    def write_rule ctx
      meth = RuleBuilder.new(ctx)
      yield meth
      meth.write
    end
  end
  class FileSexp < Sexpesque # :file
    def translate ctx
      nest = [lambda {
        if children[:definitions].any?
          ctx.builder << "# from flex name definitions"
          children[:definitions].each{ |c| c.translate(ctx) }
        end
        if children[:rules].any?
          ctx.builder << "# flex rules"
          children[:rules].each{ |c| c.translate(ctx) }
        end
      }]
      if ctx.key?(:grammar)
        parts = ctx[:grammar].split('::')
        gname = parts.pop
        nest.push lambda{
          ctx.builder.grammar_declaration(gname, & nest.pop)
        }
        while mod = parts.pop
          nest.push lambda{
            mymod = mod
            lambda {
              ctx.builder.module_declaration(mymod, & nest.pop)
            }
          }.call
        end
      end
      nest.pop.call
    end
  end
  class StartDeclarationSexp < Sexpesque # :start_declaration
    def translate ctx
      case children[:declaration_value]
      when 'case-insensitive' ; ctx.case_insensitive!
      else
        ctx.builder <<
          "# declaration ignored: #{children[:declaration_value].inspect}"
      end
    end
  end
  class ExplicitRangeSexp < Sexpesque # :explicit_range
    class << self
      def bounded min, max
        min == '0' ? new('..', max) : new(min, '..', max)
      end
      def unbounded min
        new min, '..'
      end
      def exactly int
        new int
      end
    end
    def initialize *parts
      @parts = parts
    end
    def translate ctx
      ctx.builder.write " #{@parts.join('')}"
    end
  end
  class NameDefinitionSexp < Sexpesque # :name_definition
    include RuleWriter
    def translate ctx
      write_rule(ctx) do |m|
        m.rule_name = children[:name_definition_name]
        m.pattern_like = children[:name_definition_definition]
      end
    end
  end
  class RuleSexp < Sexpesque # :rule
    include RuleWriter

    # this is pure hacksville to deduce meaning from actions as they are
    # usually expressed in the w3c specs with flex files -- which is always
    # just to return the constant corresponding to the token
    def translate ctx
      action_string = children[:action].my_text_value
      /\A\{(.+)\}\Z/ =~ action_string and action_string = $1
      if md = /\Areturn ([a-zA-Z_]+);\Z/.match(action_string)
        from_constant(ctx, md[1])
      elsif md = %r{\A/\*([a-zA-Z0-9 ]+)\*/\Z}.match(action_string)
        from_constant(ctx, md[1].gsub(' ','_')) # extreme hack!
      else
        ctx.err.write "notice: Can't deduce a treetop rule name from: "
        ctx.err.write action_string.inspect
        ctx.err.puts "  Skipping."
      end
    end
    def from_constant ctx, const
      write_rule(ctx) do |m|
        m.rule_name = const
        m.pattern_like = children[:pattern]
      end
    end
  end
  class PatternChoiceSexp < Sexpesque # :pattern_choice
    def translate ctx
      (1..(last = size-1)).each do |idx|
        self[idx].translate(ctx)
        ctx.builder.write(' / ') if idx != last
      end
    end
  end
  class PatternSequenceSexp < Sexpesque # :pattern_sequence
    def translate ctx
      (1..(last = size-1)).each do |idx|
        self[idx].translate(ctx)
        ctx.builder.write(' ') if idx != last
      end
    end
  end
  class PatternPartSexp < Sexpesque # :pattern_part
    def translate ctx
      self[1].translate(ctx)
      self[2] and self[2][:range].translate(ctx)
    end
  end
  class UseDefinitionSexp < Sexpesque # :use_definition
    def translate ctx
      ctx.builder.write ctx.flex_name_to_rule_name(self[1])
    end
  end
  class LiteralCharsSexp < Sexpesque # :literal_chars
    terminal!
    def translate ctx
      ctx.builder.write self[1].inspect # careful! put lit chars in dbl "'s
    end
  end
  class CharClassSexp < Sexpesque # :char_class
    terminal! # no guarantee this will stay this way!
    def translate ctx
      ctx.builder.write( ctx.case_insensitive? ?
        case_insensitive_hack(my_text_value) : my_text_value )
    end
    def case_insensitive_hack txt
      s = StringScanner.new(txt)
      out = ''
      while found = s.scan_until(/[a-z]-[a-z]|[A-Z]-[A-Z]/)
        repl = (/[a-z]/ =~ s.matched) ? s.matched.upcase : s.matched.downcase
        s.scan(/#{repl}/) # whether or not it's there scan over it. careful!
        out.concat("#{found}#{repl}")
      end
      "#{out}#{s.rest}"
    end
  end
  class HexSexp < Sexpesque # :hex
    terminal!
    def translate ctx
      ctx.builder.write "OHAI_HEX_SEXP"
    end
  end
  class OctalSexp < Sexpesque # :octal
    terminal!
    def translate ctx
      ctx.builder.write "OHAI_OCTAL_SEXP"
    end
  end
  class AsciiNullSexp < Sexpesque # :ascii_null
    terminal!
    def translate ctx
      ctx.builder.write "OHAI_NULL_SEXP"
    end
  end
  class BackslashOtherSexp < Sexpesque # :backslash_other
    terminal!
    def translate ctx
      # byte per byte output the thing exactly as it is, but wrapped in quotes
      ctx.builder.write "\"#{my_text_value}\""
    end
  end
  class ActionSexp < Sexpesque # :action
    terminal! # these are hacked, not used conventionally
  end
  class AutoSexp < Sexpesque
    def translate ctx
      self[1..size-1].each do |c|
        if c.respond_to?(:translate)
          c.translate(ctx)
        else
          ctx.builder.write c
        end
      end
    end
  end
end

module Hipe::ConvoGrammar
  class << self
    def cli
      @cli ||= Cli.new
    end
  end
  class ProgressiveOutputAdapter
    def initialize stream
      @out = stream
    end
    def <<(*a)
      @out.write(*a)
      self
    end
  end
  class TreetopBuilder < ::Treetop::Compiler::RubyBuilder
    def initialize ctx
      super()
      @c = ctx
    end
    def progressive_output!
      @ruby = ProgressiveOutputAdapter.new(@c.out)
    end
    def rule_declaration name, &block
      self << "rule #{name}"
      indented(&block)
      self << "end"
    end
    def grammar_declaration(name, &block)
      self << "grammar #{name}"
      indented(&block)
      self << "end"
    end
    def write *a
      @ruby.<<(*a)
    end
  end
end


Hipe::ConvoGrammar::ParserExtlib = lambda do
  # CompiledParser#failure_reason overridden for less context
  def failure_reason
    return nil unless (tf = terminal_failures) && tf.size > 0
    "Expected " +
      ( tf.size == 1 ?
        tf[0].expected_string.inspect :
        "one of #{tf.map{|f| f.expected_string.inspect}.uniq*', '}"
      ) + " at line #{failure_line}, column #{failure_column} " +
      "(byte #{failure_index+1}) after#{my_input_excerpt}"
  end

  def num_lines_ctx; 4 end

  def my_input_excerpt
    num = num_lines_ctx
    slicey = input[index...failure_index]
    all_lines = slicey.split("\n", -1)
    lines = all_lines.slice(-1 * [all_lines.size, num].min, all_lines.size)
    nums = failure_line.downto(
      [1, failure_line - num + 1].max).to_a.reverse
    w = nums.last.to_s.size # greatest line no as string, how wide?
    ":\n" + nums.zip(lines).map do |no, line|
      ("%#{w}i" % no) + ": #{line}"
    end.join("\n")
  end
end

Hipe::ConvoGrammar::TreetopGrammar = <<'GRAMMAR'
module Hipe
module ConvoGrammar
grammar Foo
  rule document
    word_or_phrase word_or_phrase*
  end

  rule word_or_phrase
    (quoted_phrase / word) DELIMITER
  end

  rule quoted_phrase
    DQUOTE (!DQUOTE . / '\"')+ DQUOTE ('~' DIGIT+)?
  end

  rule word
    (!DELIMITER .)+
  end

  rule DQUOTE
    '"'
  end

  rule DIGIT
    [0-9]
  end

  rule DELIMITER
    COMMA ' '? / LINEBREAK / ' '
  end

  rule COMMA
    ','
  end

  rule LINEBREAK
    "\r\n" / "\n" / "\r"
  end
end
end
end
GRAMMAR

__FILE__ == $PROGRAM_NAME and Hipe::ConvoGrammar.cli.run(ARGV)
