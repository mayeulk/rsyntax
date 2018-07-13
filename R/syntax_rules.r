#' Apply queries created with \link{tquery}
#'
#' @param tokens   A tokenIndex data.table, created with \link{as_tokenindex}, or any data.frame with the required columns (see \link{tokenindex_columns}).
#' @param ...      tquery functions, as created with \link{tquery}. Can also be a list with tquery functions.
#' @param as_chain If TRUE, Nodes that have already been assigned assigned earlier in the chain will be ignored (see 'block' argument).
#' @param block    Optionally, specify ids (doc_id - token_id pairs) where find_nodes will stop (ignoring the id and recursive searches through the id). 
#'                 Can also be a data.table returned by (a previous) apply_queries, in which case all ids are blocked. 
#' @param check    If TRUE, return a warning if nodes occur in multiple patterns, which could indicate that the find_nodes query is not specific enough.
#'
#' @return        A data.table in which each row is a node for which all conditions are satisfied, and each column is one of the linked nodes 
#'                (parents / children) with names as specified in the save argument.
#'                
#' @examples
#' ## it's convenient to first prepare vectors with relevant words/pos-tags/relations
#' .SAY_VERBS = c("tell", "show","say", "speak") ## etc.
#' .QUOTE_RELS=  c("ccomp", "dep", "parataxis", "dobj", "nsubjpass", "advcl")
#' .SUBJECT_RELS = c('su', 'nsubj', 'agent', 'nmod:agent') 
#' 
#' quotes_direct = tquery(select = lemma %in% .SAY_VERBS,
#'                          children(save = 'source', p_rel = .SUBJECT_RELS),
#'                          children(save = 'quote', p_rel = .QUOTE_RELS))
#' quotes_direct ## print shows tquery
#' 
#' tokens = subset(tokens_corenlp, sentence == 1)
#' 
#' nodes = apply_queries(tokens, quotes_direct)
#' nodes
#' annotate(tokens, nodes, column = 'example')
#' 
#' @export
apply_queries <- function(tokens, ..., as_chain=T, block=NULL, check=T) {
  r = list(...)
  
  is_tquery = sapply(r, is, 'tQuery')
  r = c(r[is_tquery], unlist(r[!is_tquery], recursive = F))
  
  out = vector('list', length(r))
  
  for (i in 1:length(r)){
    .TQUERY_NAME = names(r)[i]
    .TQUERY_NAME = ifelse(is.null(.TQUERY_NAME), '', as.character(.TQUERY_NAME))
    args = r[[i]]
    #nodes = find_nodes(tokens, )
    #nodes = do.call(r[[i]], args = list(tokens=tokens, block=block, check=check, e=parent.frame()))
    l = c(args$lookup, args$nested, list(tokens=tokens, select=args$select, g_id=args$g_id, save=args$save, block=block, check=check, e=parent.frame()))
    nodes = do.call(find_nodes, args = l)
    if (!is.null(nodes)) {
      nodes[,.TQUERY := .TQUERY_NAME]
      if (as_chain) block = block_ids(block, nodes)
      out[[i]] = nodes  
    }
  }
  data.table::rbindlist(out, fill=T)
} 

recprint <- function(x, level=1, connector='└') {
  if (level > 1) {
    cat(rep('  ', level-1), connector, ifelse(x$level == 'children', ' c', ' p'), ' ', sep='')
    if (!is.na(x$save)) cat(x$save, sep='') else cat('...', sep='')
    
    l = x$lookup
    for (n in names(l)) {
      v = if (class(l[[n]]) %in% c('factor','character')) paste0('"',l[[n]],'"') else l[[n]]
      v = paste(v, collapse=',')
      cat(', ', n, '=', v, sep='')
    }
    cat('\n', sep='')
  }
  for (i in seq_along(x$nested)) {
    if (i == length(x$nested))
      recprint(x$nested[[i]], level+1, '└')
    else
      recprint(x$nested[[i]], level+1, '├')
  }
}

#' S3 print for tQuery class
#'
#' @param x a tQuery
#' @param ... not used
#'
#' @method print tQuery
#' @examples
#' q = tquery(select = lemma %in% .VIND_VERBS, 
#'                    children(save = 'source', p_rel=.SUBJECT_REL),
#'                    children(p_rel='vc', select = POS %in% c('C', 'comp'),
#'                             children(save='quote', p_rel=.SUBJECT_BODY)))
#' q 
#' @export
print.tQuery <- function(x, ...) {
  if (!is.na(x$save) &! x$save == '') cat(x$save, '\n', sep = '') else cat('...', sep='')
  cat('\n', sep='')
  recprint(x)
}

#queries = alpino_quote_queries()
#print(queries)

