/*---------------------------------------------------------------------------
  Copyright 2013 Microsoft Corporation.
 
  This is free software; you can redistribute it and/or modify it under the
  terms of the Apache License, Version 2.0. A copy of the License can be
  found in the file "license.txt" at the root of this distribution.
---------------------------------------------------------------------------*/

// Format _block_ elements and and their inline elements.
module formatBlock

import std/string
import std/regex
import std/dict
import std/log
import common
import attributes // mergeDefault
import block
import inline
import formatInline
import htmlFormatter
import texFormatter


public struct formatContext( 
  inlineContext : inlineContext,
  tocBlocks   : dict<block>,
  footnoteBlock : block,
  titleinfo : titleinfo,
  headingBase: int,
  langPrefix : string,
  pedantic : bool,
  lineMap : lineMap,
  fmt : formatter = FmtHtml
)

public function initialFormatContext( icontext : inlineContext, lineMap: lineMap, titleinfo : titleinfo, 
                                      headingBase : int, pedantic : bool, fmt : formatter ) {
  FormatContext(icontext,dict(),Empty,titleinfo,headingBase,"language-",pedantic, lineMap, fmt)
}

function fmtEnv( context : formatContext, env : string, txt : string, attrs : attrs = attrsNone ) : string {
  match(context.fmt) {
    FmtHtml | context.inlineContext.bench -> tagEnv(env, txt, attrs, context.inlineContext.sanitize) // inline for efficiency
    _ -> context.inlineContext.fmtEnv(env,txt,attrs)
  }
}

function fmtCmd( context : formatContext, cmd : string, txt : string, attrs : attrs = attrsNone ) : string {
  match(context.fmt) {
    FmtHtml | context.inlineContext.bench -> tagEnv(cmd, txt, attrs, context.inlineContext.sanitize) // inline for efficiency
    _ -> (context.inlineContext.xfmtCmd)(context.inlineContext,cmd,txt,attrs)
  }
}

function fmtText( context : formatContext, txt : string ) : string {
  match(context.fmt) {
    FmtHtml -> txt  // inline for efficiency
    _       -> (context.inlineContext.xfmtCmd)(context.inlineContext,"",txt,attrsNone)
  }
}

function fmtTitle( context : formatContext ) : string {
  (context.inlineContext.xfmtTitle)(context.inlineContext,context.titleinfo)
}

function fmtTable( context : formatContext, head : list<row>, body : list<row>, colattrs : list<attrs>, attrs : attrs = attrsNone ) : string {
  (context.inlineContext.xfmtTable)(context.inlineContext,head,body,colattrs,attrs)
}

function escapeMath( txt : string, fmt : formatter ) : string {
  match(fmt) {
    FmtHtml -> txt.htmlEscape
    FmtTex  -> txt 
  }
}

/* --------------------------------------
  Process inline text in the blocks 
---------------------------------------- */

// Format blocks into html and parse and format all inline elements 
public function formatBlocks( context : formatContext, blocks : list<block> ) : string
{
  unsafeNoDiv{ formatBlocksX(context,blocks) }
}

public function formatBlocksX( context : formatContext, blocks : list<block> ) : div string
{
  formatBlocksAcc(context,blocks,builder()) 
}

function formatBlocksAcc( context : formatContext, blocks : list<block>, acc : builder<h> ) : <st<h>,div> string
{
  match(blocks) {
    Nil -> acc.string
    Cons(block,rest) -> {
      match(block) {
        // inside lists we do not parse paragraphs, but parse per line
        // (because adjacent nested lists otherwise become part of a paragraph)
        // Here we re-discover paragraphs by treating lines that are ended by
        // a blank line as a paragraph again.
        Line(txt,loose,attrs) -> {
          val (lines,rest2) = rest.span(isLine)
          val content = txt + lines.map(lineText).join
          match(rest2) {
            Cons(Blank(_),rest3) -> {
              formatBlocksAcc(context,rest3,acc.append(formatBlock(context,Para(content,attrs))))
            }
            _ -> {
              // This is to emulate fully pedantic list mode where we always
              // combine text lines as a paragraph in a loose list
              val newblock = if (loose) then Para(content,attrs) else Line(content,loose,attrs)
              formatBlocksAcc(context,rest2,acc.append(formatBlock(context,newblock)))
            }
          }
        }
        // For TeX output, an equation or list environment should be part of a paragraph
        // If a paragraph is followed by a `.para-block` we mark the paragraph as `.para-continue` 
        Para(text,attrs) | !(context.inlineContext.bench) -> {
          match(rest) {
            Cons(Div(_,attrsd),_) | attrsd.hasClass("para-block") -> {
              formatBlocksAcc(context,rest,acc.append(formatBlock(context,Para(text,attrs.addClass("para-continue")))))
            }
            Cons(List,_) -> {
              formatBlocksAcc(context,rest,acc.append(formatBlock(context,Para(text,attrs.addClass("para-continue")))))
            }
            _ -> {
              formatBlocksAcc(context,rest, acc.append(formatBlock(context,block)))
            } 
          }
        }

        // otherwise just proces the block element.
        _ -> formatBlocksAcc(context,rest, acc.append(formatBlock(context,block)))
      }
    }
  }
}

function lineText( b :  block ) {
  match(b) {
    Line(txt) -> txt
    _         -> ""
  }
}

function getLineInfo( attrs : attrs ) : string {
  match(attrs.hasKey("data-line")) {
    Just(info) -> "% data-line={" + info + "}\n" 
    Nothing    -> ""    
  }
}

function deriveCodeLineInfo( attrs : attrs ) : attrs {
  match(attrs.hasKey("data-line")) {
    Just(info) -> {
      attrsNone.addKeyval("data-line-code",info)
    }
    Nothing    -> attrsNone
  }
}

/* --------------------------------------
   Output a single block element 
---------------------------------------- */

public function formatBlock( context : formatContext, block : block ) : div string 
{
  match(block) {
    Para(txt,attrs) -> {
      val content = formatInline(context.inlineContext, txt, attrs)
      if (attrs.notag)
       then context.fmtEnv("div", content, attrs) // content
      elif (content.contains(rxblank)) then "" else 
       context.fmtEnv("p", content, attrs)      
       //"<p>" + formatInline(context.inlineContext,txt) + "</p>"
    }

    Line(txt,_loose,attrs) -> {
      formatInline(context.inlineContext, txt, attrs)
    }

    Blank -> {
      match(context.fmt) {
        FmtTex -> ""
        _      -> "\n"
      }
    }
    
    Code(txt,_,attrs) -> {      
      context.inlineContext.fmtCode( "pre", txt, attrs)
    }

    List(tagname,items,attrs) -> {
      context.fmtEnv(tagname, formatBlocksX(context,items), attrs)
    }
    
    Item(bs,attrs)  -> {
      context.fmtEnv("li", formatBlocksX(context,bs), attrs)    
    }
     
    Heading(d,txt,attrs) -> { 
      context.fmtCmd("h" + (d + context.headingBase -1).show, formatInline(context.inlineContext,txt,attrs), attrs)
    }

    HLine(attrs) -> {
      match(context.fmt) {
        FmtHtml -> "\n<hr " + attrs.htmlFormat("hr",context.inlineContext.sanitize) + ">\n" 
        _ -> context.fmtCmd("hr", "", attrs)
      }
    }
    
    Source(txt,input,parentAttrs) -> {
      match(input) {
        Pre       -> {
          context.inlineContext.fmtCode("pre",txt,parentAttrs.deriveCodeLineInfo)
        }
        Math      -> {
          //("\\[" + txt.trim.escapeMath(context.fmt) + "\\]")
          // context.logLineInfo(parentAttrs)
          context.inlineContext.fmtMath(True,txt,parentAttrs.deriveMathAttrs,getLineInfo(parentAttrs))
        }
        MathPre   -> {
          // ("\\[" + txt.mathPreBlock.escapeMath(context.fmt) + "\\]")
          // context.logLineInfo(parentAttrs)
          context.inlineContext.fmtMath(True,txt.mathPreBlock,parentAttrs.deriveMathAttrs,getLineInfo(parentAttrs))
        }
        MathDefs  -> {
          //context.logLineInfo(parentAttrs)
          val lineInfo = getLineInfo(parentAttrs)
          val mtxt = txt.escapeMath(context.fmt)
          match(context.fmt) {
            FmtTex  -> lineInfo + mtxt
            FmtHtml -> {
              log("math-pdf","% math definitions\n" + lineInfo + txt + "\n")
              if (context.inlineContext.mathStatic) {
                log("math-dvi","% math definitions\n" + lineInfo + txt + "\n")
                ""
              }
              else {
                "\\[" + mtxt + "\\]"
              }
            }
          }
        }
        Markdown  -> context.inlineContext.formatInline(txt,parentAttrs)
        Raw(monly)-> {
          if (context.inlineContext.sanitize) then ""
          else match(monly) {
            Nothing -> txt
            Just(f) | f == context.fmt -> txt
            _       -> "" 
          }
        }
        // these should not happen by now
        Tex  -> context.inlineContext.fmtEscapePre(txt)
      }      
    }

    Quote(bs,attrs) -> {
      context.fmtEnv("blockquote", formatBlocksX(context,bs), attrs)
    }
    
    Table(header,colstyles,cells,attrs) -> {
      val thead = formatRows(header,colstyles,context,attrs,False)
      val tbody = formatRows(cells,colstyles,context,attrs,True)
      context.fmtTable(thead,tbody, colstyles, attrs.addClass("madoko"))  
    }

    Div(Cons(Source(txt,Pre),Nil),attrs) | context.pedantic && attrs.elementName("div") == "pre" -> {
      context.formatBlock(Code(txt,""))
    }    

    Div(content,attrs) | attrs.hasClass("columns") -> {
      val cols = content.map fun(b) {
        match(b) {
          Div(bs,xs) -> {
            if (!(xs.hasClass("column"))) {
              warning( "a 'Columns' block should only contain 'Column' blocks")
            }  
            Cell(context.formatBlocksX(bs), xs)
          }
          _ -> {
            warning( "a 'Columns' block can only contain 'Column' blocks")
            Cell(context.formatBlock(b), attrsNone)
          }
        }
      }
      context.fmtTable(Nil,[Row(cols)],cols.map(fun(c){ attrsNone }),attrs)
    }    
    
    Div(content,attrs) -> {    
      val txt = formatBlocksX(context,content)
      val rnd = attrs.input
      if ((attrs.classes.isNil && attrs.keyvals.isNil && attrs.name=="") || attrs.notag || rnd.isRaw || 
            (context.fmt==FmtTex && rnd.isMathDefs))
        then txt 
        else context.fmtEnv("div",txt,attrs.addInputClass)
    }

    Special(name,value) -> {
      if (name.toLower=="toc") then {
        val blk = context.tocBlocks[value.toLower].maybe(Empty,id)
        formatBlock(context,blk)
      }
      elif (name.toLower=="footnotes" && context.fmt.isFmtHtml) then formatBlock(context,context.footnoteBlock)
      elif (name.toLower=="title") then context.fmtTitle()
      else "" // formatBlock(context,Para("[" + name + "]\n"))
    }
    
    DefLink       -> ""
    DefFootnote   -> ""
    Empty         -> ""
  }
}
val rxblank = regex(@"^\s*$")
val rxDashes  = regex(@"^ *(\\/)?---+ *[|+]*$") //regex(@"^( |- |-- )*---+ *[- ]*[|+]*$")
val rxDDashes = regex(@"^ *(\\/)?===+ *[|+]*$")

function deriveMathAttrs( parentAttrs : attrs ) {
  common/Attrs( classes  = parentAttrs.classes.filter(fun(c) { c.startsWith("snippet") || c.startsWith("math") } ),
         keyvals  = parentAttrs.keyvals.filter( fun(kv) {
                      val key = kv.fst
                      key.startsWith("color") || key.startsWith("font-") || key.startsWith("snippet-") || key.startsWith("math-")
                    }))
}

function formatRows( rows : list<row>, 
                      colstyles : list<attrs>, context : formatContext,
                      attrs : attrs, isBody : bool ) : list<row>
{
  if (rows.isNil) then return Nil

  function formatRow( row : list<cell>, cols : list<attrs>, rowstyle : attrs ) : list<cell> {    
    match(row) {
      Cons(cell,rs) -> {
        match(cols) {
          Cons(colstyle,cs) -> {
            // merge with row style
            val colstyle0 = colstyle.mergeDefault(rowstyle)

            // span multiple columns?
            val (txt1,colspan) = match(cell.text.find(rxbars)) {
              Nothing   -> (cell.text,1)
              Just(cap) -> (cell.text.substr(0,cap.index), cap.matched.length)
            }
            // combine borders in case of a multi-column
            val (colstyle1,cs1) = if (colspan<=1) then (colstyle0,cs) 
                                    else {
                                      val colstylex = colstyle0.addKeyval("column-span",colspan.show)
                                      val colstyley = if (isBody) then colstylex 
                                                       else colstylex.addKeyval("text-align",rowstyle.hasKey("text-align").maybe("center",id))
                                      match(cs.drop(colspan-2)) {
                                       Cons(colstylez,csx) 
                                           -> (colstyley.addClasses(colstylez.classes.filter(noalign))
                                                        .addKeyval("column-span",colspan.show), 
                                               csx )
                                       Nil -> (colstyley.addKeyval("column-span",colspan.show),Nil)
                                      }
                                    }
            // horizontal line?
            val (colstyle2,txt2) = if (txt1.contains(rxDashes))
                                    then (colstyle1.addClass("cell-line"), "")
                                   elif (txt1.contains(rxDDashes))
                                    then (colstyle1.addClass("cell-double-line"), "")
                                    else (colstyle1,txt1)
            
            val elem = Cell(context.inlineContext.formatInline(txt2,colstyle2), colstyle2)
            Cons(elem, formatRow(rs,cs1, rowstyle))        
          }
          _ -> Nil
        }
      }
      _ -> Nil  
    }
  }
  
  
  function addRowKey( target : string, key : string, test : bool ) : list<(string,string)> {
    if (!test) then [] else {
      match(attrs.hasKey(key)) {
        Nothing -> []
        Just(value) -> [(target,value)]
      }
    }
  }

  function filterKeyvals( keyvals : list<(string,string)>, pre : string ) : list<(string,string)> {
    keyvals.filterMap fun(kv) {
      val (key,value) = kv
      if (key.startsWith(pre)) then Just( (key.substr(pre.length), value) ) else Nothing
    }
  }

  function defaultKeyvals( hasLine :  bool, rowNum : int ) : list<(string,string)> {
    val mod = if (rowNum.even && rowNum != 0) then "even-" else "odd-"
    val kvs = attrs.keyvals.filterKeyvals("cell-") +
               attrs.keyvals.filterKeyvals(if (isBody) then "tr-" else "th-") +
                attrs.keyvals.filterKeyvals((if (isBody) then "tr-" else "th-") + mod) 
    if (hasLine)
     then kvs.filter(fun(kv){kv.fst.startsWith("background-color") || kv.fst.startsWith("rule") })
     else kvs
  }

  function containsDashes( row : row ) : bool {
    row.cells.any( fun(cell) { cell.text.contains(rxDashes) || cell.text.contains(rxDDashes) })
  }
         
  var rowNum := 0
  var rowCount := 0
  val firstHasLine = rows.take(1).all(containsDashes)
  val lastHasLine  = rows.reverse.take(1).all(containsDashes)
  rows.map fun(row) {
    rowCount := rowCount+1
    val hasLine = row.containsDashes
    if (!hasLine) then rowNum := rowNum+1  
    val rowstyle = row.rowAttrs.addKeyvals( 
        addRowKey("rule-width", "rule-top-width", !isBody && rowNum==0 ) +
        addRowKey("rule-width", "rule-mid-width", isBody && rowNum==0 ) +
        addRowKey("rule-width", "rule-bottom-width", isBody && hasLine && rowCount == rows.length ) +
        addRowKey("rule-width", "rule-width", True ) +
        addRowKey("padding-top", "rule-top-sep", !isBody && firstHasLine && rowNum==1 && !hasLine ) +
        addRowKey("padding-top", "rule-mid-sep", isBody && rowNum==1 && !hasLine) +
        addRowKey("padding-bottom", "rule-mid-sep", !isBody && !hasLine && rowCount == rows.length ) +
        addRowKey("padding-bottom", "rule-bottom-sep", isBody && !hasLine && lastHasLine && rowCount == rows.length-1 ) 
      )
      .addKeyvals( defaultKeyvals(hasLine,rowNum) )
    Row(formatRow(row.cells,colstyles,rowstyle),rowstyle)
  }
}
val rxbars = regex(@"[|+]+$")

function noalign( s : string ) : bool = !(s.startsWith("align-"))
