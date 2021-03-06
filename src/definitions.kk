/*---------------------------------------------------------------------------
  Copyright 2013 Microsoft Corporation.
 
  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the file "license.txt" at the root of this distribution.
---------------------------------------------------------------------------*/

// Process definitions: links, footnotes, labels, and counters
module definitions

import std/dict
import std/regex
import std/log
import std/path
import std/string
import common
import options
import attributes
import block
import inline     
import formatBlock   // just the formatContext
import formatInline  // just for rxLink
import texParser

// Parse source into blocks (see "parseBlocks") and 
// process all definitions (see "parseDefinitions").
public function parseBody( fcontext : formatContext,
                           lineNo : int,
                           src : string,
                           metadata : metadata, 
                           tocDepth : int,
                           secBase : int,
                           secDepth : int ) :  div (list<block>,formatContext)
{
  parseDefinitions(fcontext, [Div([],("notag line-adjust=0 line=" + lineNo.show).parseAttrs("body",src))], 
                   metadata,tocDepth,secBase,secDepth)
}

// Visits all blocks and returns a dictionary of links, labels, footnotes,
// a footnote block, and a table-of-contents block. 
public function parseDefinitions( 
                     fcontext : formatContext,
                     blocks : list<block>,
                     metadata : metadata, 
                     tocDepth : int = 0,
                     secBase : int = 1,
                     secDepth : int = 6 ) :  div (list<block>,formatContext)
{
  if (fcontext.inlineContext.bench) 
    then parseDefinitionsBench(fcontext,blocks)
    else parseDefinitionsFull(fcontext,blocks,metadata,tocDepth,secBase,secDepth)
}

// Fast version for benchmarking
function parseDefinitionsBench( 
                     fcontext : formatContext,
                     blocks : list<block> ) :  div (list<block>,formatContext)
{
  val links  = mdict()

  blocks.foreach fun(block) {
    match(block) {
      DefLink(id,link) -> {
        links[id] := link          
      }
      _ -> ()
    }
  }

  (blocks, fcontext( fcontext.inlineContext.copy( links=links.freeze ), dict(), Empty)  )
}


// Full version that does attribute processing
function parseDefinitionsFull( 
                     fcontext : formatContext,
                     blocks : list<block>, 
                     mdata : metadata,
                     tocDepth : int = 0,
                     secBase : int,
                     secDepth : int ) :  div (list<block>,formatContext)
{
  val counters = mdict()
  val nested   = mdict()
  val labels   = mdict()
  val links    = mdict()
  val footnotes = mdict()
  var footnoteCount := 0
  var footnoteItems := Nil
  var tocs := mdict()
  var footnotesAtEnd := True
  
  // initialize defaults from metadata
  val mdefaultAttrs = mdict()
  mdata.initializeDefaults(mdefaultAttrs,labels,counters,nested)
  val defaultAttrs : dict<string> = mdefaultAttrs.freeze()

  // process attributes 
  function process( attrs : attrs, previousIsPar : bool, block : block ) : <div,st<_h>> block {
    val bname = block.blockName
    
    // merge and set default attributes
    val attrsd  = if (!(attrs.defaults)) then attrs
                  else {
                    val attrsy = defaultAttrs.matchRules(bname,attrs)
                    if (attrsy.name != "" && attrsy.label=="") then attrsy( label = "@"+bname ) else attrsy
                  } 
    //adjust counters
    if (bname!="" && attrs.defaults) counters.adjustCounter(bname,"",nested)

    attrsd.common/counters.foreach fun(cv) {
      val (counter,value) = cv
      counters.adjustCounter(counter,value,nested)
    }

    // expand counters in label
    val cmdata = fcontext.inlineContext.metadata
    val attrsx0 = attrsd.expandCounters(counters,cmdata).expand(cmdata)

    // create a nice caption for headings
    val attrsx  = match (block) {
                    Heading(_,txt) -> {
                      val caption = attrsx0.lookupKey("caption",txt)
                      val ecaption = attrsx0.transformText(caption,dict(),fcontext.inlineContext.metadata)
                      val xcaption = ecaption.expandKeys(attrsx0.source,attrsx0,dict(),fcontext.inlineContext.metadata)
                      val kvs = [("caption",xcaption)] + (if (!attrsx0.hasKey("toc").bool) then [] else [("bookmark",xcaption.unformat)])
                      attrsx0.addKeyvals(kvs)
                    }
                    _ -> attrsx0
                  }


    // set label
    if (attrsx.name != "") then {
      val labelCaption = attrsx.hasKey("caption").maybe("",id)
      labels[attrsx.name] := Label(bname,attrsx.label,labelCaption)   
      match (attrsx.hasKey("cite-label")) {
        Nothing -> ()
        Just(clabel) -> {
          val clabelx = clabel.expandKeys(attrsx.source,attrsx,dict(),fcontext.inlineContext.metadata)
          labels["@" + attrsx.name] := Label(bname,clabelx,labelCaption)
        }
      }
    }

    // paragraph indentation
    val attrsp = match(block) {
      Para | previousIsPar -> attrsx.addClass("indent")
      _ -> attrsx
    }

    // render
    val rblock = block.setAttrs(attrsp,fcontext) 

    // toc
    match (attrsp.hasKey("toc")) {
      Nothing -> ()
      Just(value) -> {
        val entry = match(rblock) {
          Heading(d,txt,xs) -> {
            (d,xs.addKeyval("toc-line",txt))  // note: txt is processed already
          }
          _ -> {
            val depth = attrsp.lookupKey("toc-depth","1").parseInt.maybe(1,id)
            (depth,attrsp)
          }
        }
        tocs[value.toLower] := Cons(entry, tocs[value.toLower].maybe([],id))
      }
    }

    // return
    rblock
  }

  // process a block
  function parseDefBlock( previousIsPar : bool,  block : block ) : <st<_h>,div> block {
    val attrs : attrs = match(block) {
      DefLink(id,link) -> {
        links[id] := link
        // defining a relative image link causes it to be retained in the online editor
        if (link.href.relative && link.href.extname.mimeFromExt.startsWith("image/")) {
          log("filesRefer",link.href);
          if (link.href.extname == ".eps") log("filesRefer",link.href.changeExt(".png")) // refer to png too for eps images (so both latex and html will work)
        }
        attrsNone  
      }
      DefFootnote(id,content) -> {
        footnoteCount := footnoteCount+1
        val ncontent = content.mapBlocks(parseDefBlock)
        footnotes[id] := Footnote("&fn-" + id + ";", 
                                   fun(ictx){ formatBlocks(fcontext(inlineContext=ictx),ncontent) },
                                   extractCaption(ncontent))
        footnoteItems := Cons(ncontent,footnoteItems)        
        attrsNone                
      }
      Para(attrs=xs)  -> xs
      Code(_,lang,xs)  -> {
        if (lang=="") then xs else {
          xs.addKeyval("language",lang).addClass("language-" + lang)
        }
      }
      Quote(attrs=xs) -> xs
      List(attrs=xs)  -> xs
      Item(attrs=xs)  -> xs
      HLine(attrs=xs) -> xs
      Table(attrs=xs) -> xs
      Div(attrs=xs)   -> xs
      Heading(_,txt,xs) -> xs.generateHeaderId(txt)
      Special(name) -> {
        if (name == "FOOTNOTES") then footnotesAtEnd := False
        attrsNone
      }
      _ -> attrsNone
    }

    attrs.process( previousIsPar, block )
  }
  
  val newblocks  = blocks.mapBlocks(parseDefBlock)
  val labelsDict = labels.freeze()
  val tocBlocks  = //if (tocDepth <= 0) then Empty else createToc(headings.reverse)
                    (tocs.list.map fun(entry) {
                       (entry.fst, createToc(entry.snd.reverse,labelsDict,fcontext.inlineContext.metadata))
                     }).dict
  val footnoteBlock = if (isNil(footnoteItems)) then Empty 
                       else Div(Cons(HLine(), footnoteItems.reverse.concat), Attrs(classes=["footnotes","madoko"]))
  val fblocks       = if (!footnotesAtEnd) then newblocks else (newblocks + [Special("FOOTNOTES")])

  val secblocks = fblocks.sections(secInit(secBase=secBase,secMax=secDepth,secDefaults=fun(a){ defaultAttrs.matchRules("section",a) }))

  (secblocks,                   
   fcontext( fcontext.inlineContext.copy( links=links.freeze, labels=labelsDict, 
                                          footnotes=footnotes.freeze, defaults=defaultAttrs ),
              tocBlocks, footnoteBlock )  )
}

struct secinfo(
  level   : int,  // current level; start at 1
  secMax  : int,  // max level for sections 
  secBase : int,   // level used is max(base,level) 
  secDefaults: attrs -> attrs
)

val secInit = Secinfo(1,6,1,id)
val secNone = Secinfo(1,0,1,id)

function mapBlocks( blocks : list<block>, 
                    action : (bool,block) -> <st<h>,div|e> block  ) : <st<h>,div|e> list<block> {
  var previousIsPar := False
  blocks.map fun(block) {
    val nblock = action(previousIsPar,block)
  
    match(nblock) {
      Para        -> previousIsPar := True
      Div(_,xs)   | nblock.blockName == "figure" || xs.hasClass("float") -> ()  // leave as is
      Div(_,xs)   | xs.hasClass("para-end") -> previousIsPar := True
      Code(_,_,xs)| xs.hasClass("para-end") -> previousIsPar := True
      DefLink     -> ()
      DefFootnote -> ()
      _    -> previousIsPar := False
    }
    match(nblock) {
      Div(content,xs) -> {
        val ncontent = match(content.mapBlocks(action)) {
          Cons(Para(txt,attrs),rest) | xs.tight
            -> Cons(Line(txt,False,attrs),rest)
          other -> other
        }
        Div(ncontent,xs)
      }
      Quote(content,xs)    -> Quote(content.mapBlocks(action),xs)
      List(tag,content,xs) -> List(tag,content.mapBlocks(action),xs)
      Item(content,xs)     -> Item(content.mapBlocks(action),xs)
      //DefFootnote(id,content) -> DefFootnote(id,content.mapBlocks(action))
      _ -> nblock
    }
  }
}

// Sets new attributes for a block, and applies conversion to text
function setAttrs( block : block, xs : attrs, fcontext : formatContext ) : block {
  match(block) {
    HLine(_)            -> HLine(xs)                           
    Para( text )        -> Para(xs.transformText(text,dict(),fcontext.inlineContext.metadata),xs)
    Heading(depth,text) -> Heading(depth,xs.transformText(text,dict(),fcontext.inlineContext.metadata),xs)
    Table(h,cattrs,cells) -> Table(h,cattrs,cells,xs)
    List(tag,items)     -> List(tag,items,xs)
    Div( content  )     -> transformDiv(content, xs, fcontext )
    Quote( content )    -> Quote(content, xs)     
    Code( text, lang)   -> {
      if (lang=="" && !(xs.input.isPre))
        then transformDiv([Source(text)], xs(source=text,elem="pre"), fcontext )
        else Code(xs.transformText(text,dict(),fcontext.inlineContext.metadata),lang,xs)  
    }
    _                   -> block
  }
} 

function transformDiv( blocks : list<block>, attrs : attrs, fcontext : formatContext )  : block {
  if (attrs.hasKey("display").maybe("",id) == "none") return Empty
  if (attrs.hasKey("transform").maybe("",id) == "false") return Div(blocks,attrs)
  match(blocks) {                       // needed for internal divs like definition lists
    Nil              -> ()
    Cons(Source,Nil) -> ()              // but with just one Source we should transform (look above for Code transforms)
    _ -> return Div(blocks,attrs)
  }
  val citestyle = fcontext.inlineContext.citestyle
  //if (attrs.source=="") then return Div(blocks,attrs) 
  val txt = attrs.transformText(attrs.source,dict(),fcontext.inlineContext.metadata)
  match(attrs.input) {
    Tex -> {      
      Div(txt.parseTex(citestyle,fcontext.inlineContext.verbose >= 4)
        .parseBlocks(attrs.lineNo+1,fcontext.lineMap,citestyle),attrs)
    }
    Markdown(monly) -> {
      match(monly) {
        Just(mfmt)  | !(mfmt == fcontext.fmt) -> Empty
        _ -> {
          val adjLineNo = match (attrs.hasKey("line-adjust")) {
            Nothing -> attrs.lineNo + 1
            Just(d) -> attrs.lineNo + (d.parseInt().maybe(0,id))
          }
          Div(txt.parseBlocks(adjLineNo,fcontext.lineMap,citestyle),attrs)
        }
      }
    }
    input -> {
      val adjLineNo = match (attrs.hasKey("line-adjust")) {
        Nothing -> attrs.lineNo + 1
        Just(d) -> attrs.lineNo + (d.parseInt().maybe(0,id))
      }
      Div([Source(txt,input,attrs.setLineNo(fcontext.lineMap,adjLineNo))],attrs)
    }
  }  
}

// Initialize default attributes and attributes from metadata
function initializeDefaults( metadata : metadata, defaultAttrs : mdict<h,string>, labels : mdict<h,label>, 
                             counters : mdict<h,counter>, nested : mdict<h,list<string>> ) : st<h> () {
  metadata.foreach fun(kv) {
    val (key,value) = kv
    if (key.startsWith("~") || key.startsWith("#") || key.startsWith(".")) then {
      // element attributes
      // name   = key.substr(1)  // no .#~
      val attrs  = value.parseAttrs
      val dattrs = if (!(attrs.defaults)) then attrs
                   else match(defaultAttrs[key]) {
                     Nothing   -> attrs
                     Just(def) -> {
                       //trace("default merge " + name + ": " + attrs.classes.join(",") + "  def: " + def.classes.join(","))  
                       attrs.mergeDefault(def.parseAttrs) 
                     }
                   }
      defaultAttrs[key] := dattrs.text
      //trace("default " + name + ": " + dattrs.show)  
      
      // initialize counters: necessary if one for example starts with a subsection 
      // without an initial section.
      dattrs.label.findAll(rxcounter).foreach fun(cap : matched) {
        counters.setCounter(cap.groups[1].definitionId,Counter(),nested)
      }
    }
    else {
      // label key
      // labels[key] := Label("metadata",value)
      ()
    }
  }
}

function extractCaption( blocks : list<block> ) : string
{
  match(blocks) {
    Nil -> ""
    Cons(block,rest) -> {
      val post = if (rest.isNil) then "" else "&nl;..."
      match(block) {
        Heading(_,txt) -> txt + post
        Line(txt)  -> txt+post
        Para(txt)  -> txt+post
        Code(txt)  -> txt+post
        Quote(bs)  -> extractCaption(bs)
        List(_,bs) -> extractCaption(bs)
        Item(bs)   -> extractCaption(bs)
        Div(bs)    -> extractCaption(bs)
        _          -> extractCaption(rest)        
      }
    }
  }
}

//--------------------------------------------------------
// Divide into sections
//--------------------------------------------------------

function sections( blocks : list<block>, secinfo : secinfo ) : div list<block>
{
  if (secinfo.level > secinfo.secMax) return blocks
  match (blocks.findHeading(secinfo)) {
    Nothing -> blocks.sectionMap(secinfo)
    Just((pre,h,post)) -> pre.sectionMap(secinfo) + h.sectionSpan(post,secinfo)
  }
}

function sectionMap( blocks : list<block>, secinfo : secinfo ) : div list<block> 
{
  if (secinfo.level > secinfo.secMax) return blocks
  blocks.map fun(block) {
    match(block) {
      Div(content,attrs) -> {
        Div(content.sections(secinfo),attrs)
      }
      _ -> block
    }
  }
}

function sectionSpan( h : block, blocks : list<block>,  secinfo : secinfo  ) : div list<block>
{
  function createSection(content) 
  {
    val lvl = h.headingLevel(secinfo.level)
    val nsecinfo = secinfo(level=lvl+1)
    val ncontent = content.sections(nsecinfo)
    match(h) {
      Heading(d,txt,attrs) -> {
        val (skvs,hkvs) = attrs.keyvals.partition(fun(kv) { kv.fst.startsWith("data-") })
        val (scls,hcls) = attrs.classes.partition(fun(c) { c.startsWith("section-") })
        val secattrs = "html-elem=section .section" + d.show +
                        (if (attrs.name=="") then "" else " id='" + attrs.name + "'")
        val hattrs = if (attrs.name=="") then attrs else attrs(name="heading-" + attrs.name)
        val sattrs = secattrs.parseAttrs("section")
        val divattrs = (secinfo.secDefaults)(sattrs.addClasses(scls).addKeyvals(skvs))
        [Div(Cons(Heading(d,txt,hattrs(classes=hcls,keyvals=hkvs)),ncontent),divattrs)]
      }
      _ -> [h].sectionMap(nsecinfo) + ncontent
    }
  }

  match(blocks.findHeading(secinfo)) {
    Nothing -> blocks.createSection()
    Just((pre,hdr,post)) -> pre.createSection() + hdr.sectionSpan(post,secinfo)
  }    
}

function findHeading( blocks : list<block>, secinfo : secinfo ) : maybe<(list<block>,block,list<block>)>
{
  val lvl = max(secinfo.level,secinfo.secBase)
  val (pre,post) = blocks.span(fun(b) { 
    val d = b.headingLevel(lvl+1, lvl)
    (d > lvl) //  || d < secinfo.secMin
  })  
  match(post) {
    Cons(hdr,rest) -> Just((pre,hdr,rest))
    Nil -> Nothing
  }
}


function headingLevel( block : block, default : int, defaultSection : int = default ) : int {
  match(block) {
    Heading(d,_,attrs)  | !(attrs.hasClass("no-section")) -> d
    Div(_,attrs)        | attrs.hasClass("section") -> {
      match(attrs.hasKey("data-level")) {
        Just(value) -> value.parseInt.maybe(defaultSection,id)
        Nothing     -> defaultSection
      }
    }
    _  -> default
  }
}

//--------------------------------------------------------
// TOC
//--------------------------------------------------------


// Create a table of contents
function createToc( headings : list<(int,attrs)>, labels : dict<label>, metadata : dict<string> ) : div block 
{
  Div( [headings.tocItems(0,labels,metadata).tocList], Attrs(name="toc",classes=["toc"],htmlelem="nav") )
}

function tocList( items : list<block> ) : block {
  if (items.isNil) then Empty else Div(items, Attrs(classes=["tocblock"]))
}

function tocItems( headings : list<(int,attrs)>, outerDepth : int, labels : dict<label>, metadata : dict<string> ) : div list<block> {    
  match(headings) {
    Nil -> []
    Cons(hdr,hdrs) -> {
      val (depth,attrs) = hdr
      if (depth > outerDepth+1) then {
        [tocItems(headings,outerDepth+1,labels,metadata).tocList]
      }
      else {
        val (subs,rest) = hdrs.span( fun(h) { h.fst > depth } )
        val txt = attrs.lookupKey("toc-line","[??]").expandKeys(attrs.source,attrs,labels,metadata)
        val tocline = @"[\/" + txt + "](#" + attrs.name + ")"
        //trace("tocline: " + attrs.source)
        val item = Div([Line(tocline)], Attrs(classes=["tocitem"], keyvals=[("toctarget",attrs.name), ("toclevel",depth.show)]))
        val subitems = tocItems(subs,depth,labels,metadata).tocList 
        Cons(item,Cons(subitems,tocItems(rest,outerDepth,labels,metadata)))
      }
    }
  }
}

//--------------------------------------------------------
// counters
//--------------------------------------------------------

// expand counters in label,
function expandCounters( attrs : attrs, counters : mdict<h,counter>, metadata : dict<string> ) : read<h> attrs {
  val xlab = attrs.label.expandKeys(attrs.source,attrs,dict(),metadata).expandCounter(counters) 
  if (xlab != attrs.label)
   then attrs(label=xlab)
   else attrs
}

// expand the counters in a string
function expandCounter(lab : string, counters : mdict<h,counter> ) : read<h> string
{
  lab.replaceAll(rxcounter) fun(cap) {
    //trace("expand: " + lab + ": found: " + cap.groups[1] + " = " + counters[cap.groups[1]].string)
    match(counters[cap.groups[1].definitionId]) {
      Just(counter) -> counter.show
      Nothing       -> cap.matched
    }
  }  
}
val rxcounter = regex(@"(?:\\/)?@([\w\-]+)(?:\\/)?")



// adjust a counter
function adjustCounter(counters : mdict<h,counter>,name : string, value : string, nested : mdict<h,list<string>> ) : st<h> () {
  //trace("increment " + counter + " from " + counters[counter].string + " to " + incrementCounter(counters[counter].string,value))
  counters.setCounter( name, increment(counters[name].maybe(Counter(),id), value), nested )
  counters.resetNestedCounters(name,nested)
}

// increment or set a count to a value
function increment(counter :counter, xvalue : string) : counter {
  val v = xvalue.toLower
  if (v=="upper-case") then counter(counter.value,Uppercase)
  elif (v=="lower-case") then counter(counter.value,Lowercase)
  elif (v=="arabic") then counter(counter.value,Arabic)
  elif (v=="arabic0") then counter(counter.value,Arabic0)
  elif (v=="") then counter(value=counter.value+1)
  else match(xvalue.list) {
    Cons(d,Nil) | d >= 'a' && d <= 'z' -> Counter((d-'a').int+1,Lowercase)
    Cons(d,Nil) | d >= 'A' && d <= 'Z' -> Counter((d-'A').int+1,Uppercase)
    _ -> match(v.parseInt) {
      Just(i) -> counter(value=i)
      Nothing -> {
        warning( "unrecognized counter value: " + xvalue)
        counter
      }
    }
  }
}

// reset lower counters (ie. for h1-h2, reset h1-h2-h3, h1-h2-h3-h4, ...)
function resetNestedCounters(counters : mdict<h,counter>, counter : string, nested : mdict<h,list<string>> ) : st<h> ()
{  
  match(nested[counter]) {
    Nothing -> ()
    Just(cnts) -> {
      cnts.foreach fun(cnt) {
        match(counters[cnt]) {
          Nothing -> ()
          Just(c) -> counters[cnt] := c(value=0)
        }
      }
    }
  }
}
 
function setCounter( counters : mdict<h,counter>, name : string, counter : counter, nested : mdict<h,list<string>> ) : st<h> ()
{   
  if (counters[name].isNothing) {
    nested.initializeCounter( name )
  }
  counters[name] := counter;
}

function initializeCounter( nested : mdict<h,list<string>>, name : string ) : st<h> ()
{
  val prefixes = name.split("-").list.init
  prefixes.foreachIndexed fun(i,_) {
    val pre = prefixes.take(i+1).join("-")
    nested[pre] := Cons(name, nested[pre].maybe([],id))
    //trace("nested: " + pre + ": " + nested[pre].maybe([],id).join(","))
  }
}



//--------------------------------------------------------
// counter type
//--------------------------------------------------------

// The display format of a counter
type format {
  Arabic0     // start at 0
  Arabic
  Uppercase
  Lowercase
  // Roman
}

struct counter( value :int = 0, format :format = Arabic  )

function show( counter : counter ) : string {
  match(counter.format) {
    Uppercase -> counter.value.showLetterBase('A')
    Lowercase -> counter.value.showLetterBase('a')
    Arabic0   -> (counter.value-1).show
    _ -> counter.value.show
  }
}

function showLetterBase( value : int, baseChar : char) : string {
  unsafeNoDiv {
    value.showRLetterBase(baseChar).reverse.string
  }
}

function showRLetterBase( value : int, baseChar : char ) : div list<char> {
  if (value <= 0) return []
  val next = value/26
  val mod  = value%26 - (if (next == 0) then 1 else 0)
  Cons(mod.char + baseChar, next.showRLetterBase(baseChar))
}

//--------------------------------------------------------
// Unformat
//--------------------------------------------------------

function unformat( s : string ) : string {
  s.replaceAll(rxLink, fun(cap) { cap.groups[1].replaceAll(rxLink,"$1") } ).trim
}

//--------------------------------------------------------
// Block names
//--------------------------------------------------------

function blockName(block : block) : string
{
  match(block) {
    Para  -> "p"
    Code  -> "pre"
    Quote -> "blockquote"
    List(tag) -> tag 
    Item  -> "li"
    HLine -> "hr"
    Table -> "table"
    Heading(depth=d) -> "h" + d.show
    Div(attrs=xs) -> xs.elementName("div")
    _     -> ""
  }
}
