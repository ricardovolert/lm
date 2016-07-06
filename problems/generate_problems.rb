#!/usr/bin/ruby

# generate_problems.rb /path/to/spotter/dir instr data_dir instr_dir 
#   first arg is where spotter dir is
#   instr = 0 or 1, indicates whether this is the instructor's version
#   data_dir is where the following files are: fig_widths, fig_widths_by_hand, fig_exceptional_captions, fig_exceptional_naming
#   instr_dir is directory where the solutions are
# prints m4/latex output to stdout
# side-effects:
#   writes a spotter answer file to spotter.m4
#   writes to files missing_solutions and missing_checks

require 'fileutils'
require 'json'

def fatal_error(message)
  $stderr.print "generate_problems.rb: #{$verb} fatal error: #{message}\n"
  exit(-1)
end

def warning(message)
  $stderr.print "generate_problems.rb: #{$verb} warning: #{message}\n"
end

def informational_message(message)
  $stderr.print "generate_problems.rb: #{$verb} informational message: #{message}\n"
end

# returns contents or nil on error; for more detailed error reporting, see slurp_file_with_detailed_error_reporting()
def slurp_file(file)
  x = slurp_file_with_detailed_error_reporting(file)
  return x[0]
end

def slurp_or_die(file)
  x = slurp_file_with_detailed_error_reporting(file)
  x = x[0]
  if x.nil? then fatal_error("file #{file} not found") end
  return x
end

# returns [contents,nil] normally [nil,error message] otherwise
def slurp_file_with_detailed_error_reporting(file)
  begin
    File.open(file,'r') { |f|
      t = f.gets(nil) # nil means read whole file
      if t.nil? then t='' end # gets returns nil at EOF, which means it returns nil if file is empty
      return [t,nil]
    }
  rescue
    return [nil,"Error opening file #{file} for input, cwd=#{Dir.pwd}: #{$!}."]
  end
end

def get_json_data_from_file_or_die(file)
  r = slurp_file_with_detailed_error_reporting(file)
  if !(r[1].nil?) then fatal_error(r[1]) end
  return parse_json_or_die(r[0])
end

def preprocess_json(json)
  # JSON doesn't officially allow comments or multiline strings, but I want these features.
  # Ruby's parser (like many parsers) actually does allow comments, so that's not a problem.
  # The following regex allows for multiline strings using the standard JS syntax, which is a \ at end of line.
  return json.gsub(/\\\n/,"\\n")
end

def parse_json_or_die(json)
  begin
    return JSON.parse(preprocess_json(json))
  rescue JSON::ParserError
    fatal_error("syntax error in JSON string '#{m}'")
  end
end

def is_valid_json(json)
  begin   
    JSON.parse(preprocess_json(json)) # throw away result
    return true
  rescue JSON::ParserError
    return false
  end
end

# Example:
#   text looks like this:
#     foo
#     % meta {"stars":
#     % 1}
#     bar
#   keyword="meta"
#   The two % lines are recognized as a single block containing some JSON.
#   We know that it isn't a single line, because that wouldn't be syntactically valid JSON.
#   The code block is invoked with this hash as an argument. It will normally return a null string,
#   which means that the json blocks are filtered out. If it returns a string, then the json block
#   is replaced with that string.
def json_block(text,keyword)
  # expects a code block as 3rd param
  # returns [transformed text,err,error message]
  accum_block = ''
  result = ''
  line_count = 0
  text.split(/\n/).each { |line|
    line_count = line_count+1
    if line=~/\r/ then return [nil,true,"line #{line_count} contains \\r"] end
    if accum_block=='' && !(line=~/^%\s*#{keyword}[^a-zA-Z].*/) then
      result = result + accum_block + line + "\n"
    else
      if accum_block=='' then 
        line=~/^%\s*#{keyword}([^a-zA-Z].*)/
        accum_block = $1
      else
        if line =~/^%(.*)/ then
          accum_block = accum_block+$1
        else
          return [nil,true,"invalid JSON syntax in block ending at line #{line_count-1}"]
        end
      end
      if is_valid_json(accum_block) then
        result = result + yield(parse_json_or_die(accum_block)).to_s
        accum_block = ''
      end
    end
  }
  result = result + accum_block + "\n"
  return [result,false,nil]
end

def get_problems_data(problems_csv) # used in order to determine which problems have publicly available solutions
  # return value is a hash like {"mg-to-kg"=>true,...}
  # lm,0,1,calculator,0
  # book,chapter,number,label,solution
  result = {}
  csv = slurp_file(problems_csv)
  csv.split(/\n/).each { |line|
    if line=~/\A([^,]*),([^,]*),([^,]*),([^,]*),([^,]*)\Z/ then
      book,chapter,number,label,solution = [$1,$2.to_i,$3,$4,$5]
      if solution!='' then
        result[label] = (solution.to_i==1)
      end
    else
      fatal_error("can't parse this line in #{infile}: #{line}")
    end
  }
  return result
end

def filter_out_eruby(t)
  result = ''
  inside = false # even if there is a ruby expression at the very beginning of the string, split() gives us a null string as our first string
  t.split(/(?:\<\%|\%\>)/).each { |x|
    if !inside then result = result+x end
    inside = !inside
  }
  return result
end

def clean_up_hw(t)
  result = t.gsub(/^%%%%%(.*)\n/) {''}
  result,err,message = json_block(result,"meta") { |data| ''} # eliminate meta blocks
  if err then fatal_error(message) end
  result.gsub!(/\A\s+/) {''}
  result.gsub!(/\n*\Z/) {''}
  return result
end

#-------------------------------------------------------------
def find_problem_file(prob,location)
  file = $original_dir+"/../../"+location+"/hw/"+prob+".tex"
  # I put some in problems book directory before, but that was a bad idea.
  file_own = Dir.getwd+"/"+prob+".tex"
  if File.exist?(file_own) && File.exist?(file) then
    # warning("You have two versions of #{prob}; this is a bad idea; do a conditional:\n  mg #{file} #{file_own}\n  m4_ifelse(__problems,1,[:foo:],[:bar:])\n")
    # Don't throw a warning. I only have one of these left, tiptotail, and it's too complicated to be a conditional
    # without being really awkward.
    return [file_own,nil]
  end
  if File.exist?(file_own) && !(File.exist?(file)) then
    warning("You have #{prob} in the wrong place; do:\n  git mv #{file_own} #{file}\n")
    return [file_own,nil]
  end
  # if not, then look in shared directory:
  if File.exist?(file) then return [file,nil] end
  if prob=~/\.tex$/ then return [nil,"file #{file} not found, probably because you shouldn't have included .tex in this.config"] end
  return [nil,"file #{prob}.tex not found in #{Dir.getwd} or #{$original_dir+"/../../"+location+"/hw"}"]
end

def extract_meta(t)
  h = {}
  t,err,message = json_block(t,"meta") { |data|
    h = h.merge(data)
    '' # filter the block out of the source code
  }
  if err then fatal_error(message) end
  return h
end

def fig_width(fig) # fig is the bare name of the figure, e.g., "weasel", not "weasel.jpg"
  # return value is "narrow", "wide", or "fullpage"
  result = 'narrow'
  if $fig_widths.key?(fig) then result = $fig_widths[fig] end
  return result
end

def find_fig_file_in_dir(dir,f) # returns [boolean,"foo","/.../.../foo.png",width]
  # return value width is "narrow", "wide", or "fullpage"
  ["png","jpg","pdf"].each { |type|
    g = "#{dir}/#{f}.#{type}"
    if File.exist?(g) then return [true,f,g,fig_width(f)] end
  }
  return [false,nil,nil,nil]
end

def find_fig_for_problem(prob,files) # returns [boolean,"foo","/.../.../foo.png",width]
  # files = a directory, can be relative, with /figs implied on the end, or absolute
  # return value width is "narrow", "wide", or "fullpage"
  # For exceptions to the naming convention (e.g., figures that need to be duplicated in the book
  # in more than one place), edit fig_exceptional_naming.
  places = []
  if !(files.nil?) then 
    # detect whether it's relative or absolute
    if Dir.exist?(files) then
      places.push(files)
    else
      places.push($original_dir+"/../../"+files+"/figs")
    end
  end
  places.push($original_dir+"/../../me/end/figs") # me/end/figs has some figures for solutions
  possible_names = []
  if $fig_exceptional_naming.key?(prob) then
    possible_names.push($fig_exceptional_naming[prob])
  else
    ['','hw-','eg-'].each { |prefix|
      possible_names.push("#{prefix}#{prob}")
    }
  end
  possible_names.each { |f|
    places.each { |dir| 
      r = find_fig_file_in_dir(dir,f)
      if r[0] then return r end
    }
  }
  return [false,nil,nil]
end

def find_anonymous_inline_figs(tex)
  return tex.gsub(/\\anonymousinlinefig{([^}]*)}/) {
    f = ''
    find = find_fig_for_problem($1,nil)
    if find[0] then f=find[2] end
    "\\anonymousinlinefig{#{f}}"
  }
end

def find_figs_for_solution(prob,orig,label,instr_dir=nil)
  #debug = (prob=~/truck/)
  debug = false
  $stderr.print "in find_figs_for_solution, prob=#{prob}" if debug
  tex = orig.clone
  figs_dir = nil
  if !(instr_dir.nil?) then found,solution,figs_dir = find_instructor_solution(prob,instr_dir) end
  macros = ["anonymousinlinefig","fig"]
  macros.each { |m|
    tex.gsub!(/\\#{m}{([^}]*)}/) {
      fig_name = $1
      f = ''
      find = find_fig_for_problem(fig_name,figs_dir)
      if find[0] then 
        f=find[2]
      else
        fatal_error("fig not found by find_figs_for_solution, prob=#{prob}, fig_name=#{fig_name}, figs_dir=#{figs_dir}")
      end
      $stderr.print "in find_figs_for_solution, prob=#{prob}, f=#{f}" if debug
      result = "\n\n\\noindent\\begin{center}\\anonymousinlinefig{#{f}}\\end{center}\n\n" # narrow, not floating
      width = fig_width(fig_name)
      if width!='narrow' then
        result = process_fig(f,width,"Problem #{label}.",true,true,true) # floating, wide fig
      end
      result
    }
  }
  return tex
end

def generate_chapter_header(title,path_label)
  boilerplate = slurp_file("#{$original_dir}/../chapter_header_boilerplate.tex")
  if boilerplate.nil? then boilerplate='' end
  print <<-HEADER

      %%%%%%%%%%% ch: #{title} %%%%%%%%%%%
      \\chapter{#{title}}\\label{ch:#{path_label}}
      #{boilerplate}
    HEADER
end

def get_meta_data_with_default(meta,key,default)
  result = default
  if meta.key?(key) then result=meta[key] end
  return result
end

def die_if_bogus_xml(xml_file,prob)
  xml = slurp_or_die(xml_file)
  # look for, e.g., <problem id="avg-velocity-bike-ride">
  if !(xml=~/(<problem\s+id="([^"]+)">)/) then
    warning("file xml_file does not appear to have a <problem id=\"...\">")
    return
  end
  id_inside_file = $2
  if prob!=id_inside_file then
    fatal_error("in file #{xml_file}, #{$1} says id is #{$2}, should be #{prob}")
  end
end

def generate_photo_credit(fig_file)
  if $credits.key?(fig_file) then
    description,credit = $credits[fig_file]
    $credits_tex = $credits_tex + "\\cred{#{fig_file}}{#{description}}{#{credit}}"
  end
end

def generate_caption_for_hw_fig(prob,fig_file)
  if $fig_exceptional_captions.key?(fig_file) then return $fig_exceptional_captions[fig_file] end
  return "Problem \\ref{hw:#{prob}}."
end

def generate_prob_tex(prob,group,k,solutions,files,counters)
  # returns latex for the problem
  # side-effects (when appropriate):
  #   adds to $credits_tex
  #   adds to spotter output in $spotter1 and $spotter2
  #   appends to own_problems_solns.csv if the problem is marked with a meta tag as having a solution
  file,err = find_problem_file(prob,files)
  if file.nil? then fatal_error(err) end
  debug = false # (prob=~/pluto/)
  label = group+k.to_s
  tex = slurp_file(file)
  meta = extract_meta(tex)
  if $save_meta.key?(prob) then fatal_error("problem #{prob} occurs twice; second time is in prob=#{prob} group=#{group} files=#{files}") end
  $save_meta[prob] = meta
  tex = clean_up_hw(filter_out_eruby(tex))
  stars = get_meta_data_with_default(meta,"stars",0)
  ch = counters[1]
  full_label = "#{ch}-#{label}"
  if $labels.key?(full_label) then fatal_error("label #{full_label} defined twice, as #{$labels[full_label]} and #{prob}") end
  $labels[full_label] = prob
  result = <<-RESULT
    \n\n%%%%%%%%%%%%%%%% #{prob} %%%%%%%%%%%%%%%%
    \\begin{hw}{#{prob}}{#{stars}}{0}{#{ch}-#{label}}
    #{tex}\n
    RESULT
  if solutions[prob] || meta["solution"]==1 then result =result+"\\hwsoln\n" end
  if meta["solution"]==1 then
    File.open("#{$original_dir}/own_problems_solns.csv",'a') { |f|
      f.print ",#{ch},#{label},#{prob},1\n"
    }
  end
  result = result + "\\end{hw}\n"
  has_fig,fig_file,fig_path,width = find_fig_for_problem(prob,files)
  if has_fig then
    result = result+process_fig(fig_file,width,generate_caption_for_hw_fig(prob,fig_file),true,false,true)
  end
  if !($spotter_dir.nil?) then
    if debug then $stderr.print "looking for spotter stuff for #{prob}" end
    bogus_xml_filename = "#{$spotter_dir}/xml/#{prob}.tex" # misnaming it .tex, which I always do by mistake
    if File.exist?(bogus_xml_filename) then fatal_error("File #{bogus_xml_filename} exists, should end in .xml, not .tex") end
    xml_fragment = "#{$spotter_dir}/xml/#{prob}.xml"
    check_exists = File.exist?(xml_fragment)
    claims_check_exists = (tex =~ /\\answercheck/)
    if check_exists then
      $spotter1 = $spotter1 + "<num id=\"#{prob}\" label=\"#{label}\"/>\n"
      $spotter2 = $spotter2 + "m4_include(xml/#{prob}.xml)\n"
      die_if_bogus_xml(xml_fragment,prob)
    end
    if check_exists && !claims_check_exists then
      log_warning('check',"missing \\answercheck for #{prob}, #{ch}-#{label}","problem #{prob} has an answer check in #{xml_fragment},\n  but file #{file} doesn't have \\answercheck")
    end
    if !check_exists && claims_check_exists then
      log_warning('check',"missing answer check for #{prob}, #{ch}-#{label}","for problem #{ch}-#{label}, #{prob},\n  file #{File.expand_path(file)} has \\answercheck,\n  but no file #{xml_fragment} exists")
    end
  end
  return result
end

def log_warning(type,brief,message)
  if type=='check' then
    file = $missing_checks_file
    $n_missing_checks = $n_missing_checks+1
    n = $n_missing_checks
  end
  if type=='solution' then
    file = $missing_solutions_file
    $n_missing_solutions = $n_missing_solutions+1
    n = $n_missing_solutions
  end
  if n==1 then warning(brief) end
  if n==2 then warning("There are additional missing #{type}s recorded in the file #{File.basename(file)}.") end
  File.open(file,'a') { |f| f.print message+"\n" }
end

def find_instructor_solution(prob,instr_dir)
  # returns [found,file,figs_dir]
  found = false
  found_file = nil
  topics = ["intro","mechanics","waves","em-dc","em-fields","em-general","optics","relativity","quantum"]
  topics.each { |subdir|
    found_file = "#{instr_dir}/#{subdir}/#{prob}.tex"
    if File.exist?(found_file) then return[true,found_file,"#{instr_dir}/#{subdir}/figs"] end
  }
  return [false,nil,nil]
end

def clean_up_soln(orig)
  tex = orig.clone
  tex.sub!(/\A\s+/,'') # eliminate leading blank lines
  # \includegraphics{\chdir/figs/10-oclock-short} in, e.g., problem "row"
  tex.gsub!(/\\includegraphics{\\chdir\/figs\/.*}/) {''}
  tex.gsub!(/\\begin{forcetablelmonly}{([^}]*)}/) {"\\begin{forcesoln}{}{}{#{$1}}{}"}
  tex.gsub!(/\\end{forcetablelmonly}/) {"\\end{forcesoln}"}
  return tex
end

def generate_solution_tex(answers_dir,prob,group,k,path,counters,instr=false,instr_dir=nil) # qwe
  debug = false
  #debug = (prob=~/cross/)
  $stderr.print "entering generate_solution_tex, prob=#{prob}\n" if debug
  ch = counters[1]
  found = false
  instr_only = nil
  file = answers_dir+"/"+prob+".tex" # student solution
  figs_dir = nil
  if File.exist?(file) then
    found=true
    instr_only = false
  else
    found,file,figs_dir = find_instructor_solution(prob,instr_dir)
    instr_only = true
  end
  $stderr.print "file=#{file}, #{file.nil?}, found=#{found}\n" if debug
  label = "#{ch}-#{group}#{k}"
  if !instr && !found then log_warning('solution',"missing solution for #{label}, #{prob}","no solution found for problem #{label}, #{prob}, which is supposed to have a solution in the back of the student's version; solutions should typically go in physics/share/answers"); return '' end
  if instr && !found then log_warning('solution',"missing solution for #{label}, #{prob}","no solution found for problem #{label}, #{prob}"); return '' end
  label = group+k.to_s
  complete_label = "#{ch}-#{label}"
  if instr_only then
    $stderr.print "calling find_figs_for_solution, prob=#{prob}, file=#{file}\n" if debug
    soln = find_figs_for_solution(prob,slurp_file(file),complete_label,instr_dir)
  else
    soln = find_figs_for_solution(prob,slurp_file(file),complete_label)
  end
  soln = clean_up_soln(soln)
  result = ''
  result = result+"\n\n%%%%%%%%%%%%%%%% solution to #{prob} %%%%%%%%%%%%%%%%\n"
  result = result+"\\solnhdr{\\ref{ch:#{path[0]}}-#{label}}\\label{soln:#{ch}-#{label}}\n"
  result = result+soln+"\n\n\\timetraveltohere\n\n"
  $stderr.print "done with generate_solution_tex, result=#{result}\n" if debug
  return result
end

def process_fig(fig_file,width,caption,allow_time_travel,if_path,anonymous=false)
  # returns latex code for the figure; the result is floating; in solutions, this is only called for wide figs
  # has the side-effect of generating a photo credit
  # width can be narrow (52 mm), medium (1 column), wide, or fullpage
  # if_path=true means that the figure is in the usual shared figs directory; false means fig_file is a pathname
  macro = 'fignarrow'
  add_before,add_after = '',''
  if width=='medium' then
    macro='fig'
  else
    if width!='narrow' then
      macro='figwide'
      if if_path then macro='figwidepath' end
      if allow_time_travel then
        add_before="\n\\begin{timetravel}\n";add_after="\n\\end{timetravel}\n" 
      end
    end
  end
  generate_photo_credit(fig_file)
  if anonymous then macro=macro+'anon' end
  return "#{add_before}\\#{macro}{#{fig_file}}{}{#{caption}}#{add_after}\n"
end

def process_text(tex)
  # Handles figures, which look like this:
  #       % fig {"name":"munchausen","caption":"Escaping from a 
  #       %      swamp."}
  # Has the side effect of generating photo credits.
  tex,err,message = json_block(tex,"fig") { |fig_data|
    fig = fig_data["name"]
    caption = fig_data["caption"]
    if fig_data.key?("width") then width=fig_data["width"] else width = fig_width(fig) end
    allow_time_travel = true
    if fig_data.key?("timetravel") then allow_time_travel=false end
    process_fig(fig,width,caption,allow_time_travel,false) # replaces original code with this
  }
  if err then fatal_error(message) end

  if false then
  tex.gsub!(/^%\s*fig\s*({.*})$/) { |line|
    fig_data = parse_json_or_die($1)
    fig = fig_data["name"]
    caption = fig_data["caption"]
    if fig_data.key?("width") then width=fig_data["width"] else width = fig_width(fig) end
    allow_time_travel = true
    #if fig_data.key?("timetravel") then allow_time_travel=(fig_data["width"]!=0) end
    if fig_data.key?("timetravel") then allow_time_travel=false end
    process_fig(fig,width,caption,allow_time_travel,false)
  }
  end

  return tex
end

def generate_content(what,depth,json,files,group,path,solutions,answers_dir,counters)
  # depth 0=book, 1=chapter, 2=section, 3=problem group
  debug = false
  path_label = path.join('-')
  print "\\renewcommand{\\sharedfigs}{#{files}/figs}"
  if what=="text" then
    title = json["title"]
    if depth==1 then print generate_chapter_header(title,path_label) end
    if depth==2 then print "\n%%%%%%%%%%% sec: #{title} %%%%%%%%%%%\n\\section{#{title}}\\label{sec:#{path_label}}\n" end
    if File.exist?("text.tex") && depth<3 then print process_text(slurp_file("text.tex")) end
  end
  if depth==3 then
    if json.key?("order") && !(json["order"].nil?) then
      if what=="problems" && File.exist?("text.tex") then print "\\emph{"+slurp_file("text.tex")+"}" end
                       # ... instructions for a block of homework problems
      order = json["order"]
      k = 0
      order.each { |prob|
        if prob=='' then fatal_error("problem is a null string, problem group=#{group}, counters=#{counters.join(',')}") end
        k = k+1
        if what=="problems" then
          print generate_prob_tex(prob,group,k,solutions,files,counters)
                  # ... has side effects of adding to $credits_tex, $spotter1, and $spotter2, if appropriate
        end
        if what=="answers" then
          if $instructor then
            print generate_solution_tex(answers_dir,prob,group,k,path,counters,true,$instr_dir)
          else
            if $save_meta[prob].nil? then
              warning("save_meta is nil for problem #{prob} -- why?")
            end
            if (solutions.key?(prob) && solutions[prob]) || (!$save_meta[prob].nil? && $save_meta[prob]["solution"]==1) then
              print generate_solution_tex(answers_dir,prob,group,k,path,counters)
            end
          end
        end
      }
    end
  end
end

def do_stuff(what,depth,files,group,path,solutions,answers_dir,counters) # recursive
  # depth 0=book, 1=chapter, 2=section, 3=problem group
  debug = false
  counters[depth+1] = 0 # e.g., if depth=0 then set the chapter number to 0
  indent = "  "*depth
  $stderr.print "#{indent}what=#{what}, depth=#{depth}\n" if debug
  json = get_json_data_from_file_or_die("this.config")
  if json.key?("files") then files=json["files"] end
  if what=="answers" && depth==0 then
    print "\\chapter*{Answers}\n"
  end
  generate_content(what,depth,json,files,group,path,solutions,answers_dir,counters)
  if json.key?("order") then
    order = json["order"]
    if depth <= 2 then
      subdirs = []
      if order.kind_of?(Array) then
        subdirs = order
      end
      if order.kind_of?(Hash) then
        groups = order.keys.sort # bug: sort won't work if keys are like "aa", etc.
        groups.each { |g|
          subdirs.push(order[g])
        }
      end
      subdirs.each { |dir|
        save_dir = Dir.getwd
        if !File.exist?(dir) || !File.directory?(dir) then
          fatal_error("subdirectory #{dir} doesn't exist, cwd=#{save_dir}")
        end
        Dir.chdir(dir)
        g = group
        if depth==2 then g=order.key(dir) end
        path.push(dir)
        counters[depth+1] = counters[depth+1]+1
        do_stuff(what,depth+1,files,g,path,solutions,answers_dir,counters) # recursion
        path.pop
        Dir.chdir(save_dir)
      }
    end
  end
  if what=="text" && depth==1 then
    print "\\begin{hwsection}\n"
    ch = counters[1]
    $spotter1 = $spotter1+"\n\n<!-- ch #{ch}, #{json["title"]} -->\n\n"
    $spotter2 = $spotter2+"\n\n<toc type=\"chapter\" num=\"#{ch}\" title=\"#{json["title"]}\">\n\n"
    do_stuff("problems",depth,files,group,path,solutions,answers_dir,counters)
    print "\\end{hwsection}\n"
    $spotter2 = $spotter2+"\n\n</toc>\n\n"
  end
end

# Initialize globals, delete scratch files, check for some errors such as directories that don't exist.
# spotter_dir can be nil or "" if not doing spotter stuff
def init(spotter_dir,require_instructor,data_dir,instr_dir,title)
  $n_missing_solutions = 0
  $n_missing_checks = 0
  $missing_solutions_file = "#{Dir.pwd}/missing_solutions"
  $missing_checks_file = "#{Dir.pwd}/missing_checks"
  $labels = {} # used to check for uniqueness
  FileUtils.rm_f [$missing_solutions_file,$missing_checks_file]
  $instructor = require_instructor # is this the instructor's version?
  $data_dir = data_dir # contains fig_widths file
  $instr_dir = instr_dir
  if $instructor && !(Dir.exist?($instr_dir)) then
    warning("directory #{$instr_dir} doesn't exist")
    $instructor = false
  end
  $fig_widths = get_json_data_from_file_or_die("#{$data_dir}/fig_widths")
  $fig_widths = $fig_widths.merge(get_json_data_from_file_or_die("#{$data_dir}/fig_widths_by_hand"))
  $fig_widths = $fig_widths.merge(get_json_data_from_file_or_die("../override_fig_widths"))
  $fig_exceptional_captions = get_json_data_from_file_or_die("#{$data_dir}/fig_exceptional_captions")
  $fig_exceptional_naming = get_json_data_from_file_or_die("#{$data_dir}/fig_exceptional_naming")
  $original_dir = Dir.getwd

  # spotter stuff
  $spotter_dir = nil
  if !(spotter_dir.nil?) && !(spotter_dir=='') then
    $spotter_dir = spotter_dir
    if !($spotter_dir.nil?) && !(Dir.exist?($spotter_dir)) then 
      warning("spotter directory #{$spotter_dir} doesn't exist") 
      $spotter_dir = nil
    else
      $spotter1 = '' # header info for spotter .xml file
      $spotter2 = '' # body of spotter .xml file
      $spotter1 = slurp_or_die($original_dir+"/../spotter_header") 
      $spotter1 = $spotter1 + "<spotter title=\"#{title}\">\n<log_file ext=\"log\"/>\n"
      $spotter2 = ''
    end
  end
end

def finish_up()
  if !($spotter_dir.nil?) then
    File.open('spotter.m4','w') { |f|
      f.print $spotter1+"\n\n<toc_level level=\"0\" type=\"chapter\"/>"+$spotter2+"\n</spotter>\n"
    }
  end
end

def do_problems_book_main(title)
  $credits_tex = "\\input{../credits_header.tex}"
  $credits = get_json_data_from_file_or_die($original_dir+"/../photocredits.json")
  $save_meta = {}
  if $instructor then title = title+", Instructor's Edition" end
  solutions = get_problems_data($original_dir+"/../../data/problems.csv")
  answers_dir = $original_dir+"/../../share/answers"
  print <<-'TOP'
    \documentclass{problems}
    \begin{document}
    TOP
  print slurp_or_die($original_dir+"/front_matter.tex").gsub!(/__title__/) {title}
  print "\\timetravelenable"
  stuff_to_do = ["text","hints","answers"] # there is also "problems", which is triggered after the text for a chapter
  stuff_to_do.each { |what| 
    do_stuff(what,0,'','',[],solutions,answers_dir,[])
  }
  print $credits_tex
  print <<-'BOTTOM'
    \input{../postamble.tex}
    \end{document}
    BOTTOM

  $original_dir = Dir.pwd
  if $n_missing_checks>0 || $n_missing_solutions>0 then warning("#{$n_missing_solutions} missing solutions and #{$n_missing_checks} missing checks") end
end

def do_problems_book(spotter_dir,require_instructor,data_dir,instr_dir)
  book_config = get_json_data_from_file_or_die("this.config")
  title = book_config["title"]
  init(spotter_dir,require_instructor,data_dir,instr_dir,title)
  do_problems_book_main(title)
  finish_up()
end

def main()
  do_problems_book(ARGV[0],ARGV[1]=='1',ARGV[2],ARGV[3]) # spotter_dir,require_instructor,data_dir,instr_dir
end

main()
