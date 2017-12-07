#' Query parse trees by searching nodes and recursively searching their parents and/or children
#'
#' This is the primary workhorse for writing rules for quote and clause extraction.
#' Specific nodes can be selected using standard R expressions, such as: 
#' \itemize{
#' \item pos == "verb" & lemma \%in\% .SAY_VERBS
#' }
#' Then, from the position of these nodes, you can lookup children, optionally with 
#' another select expression. This can be done recursively to find children of children etc. 
#' 
#' To look for parents or children, use the \link{parents} and \link{children} functions (and optionally \link{all_parents} or \link{all_children}).
#' Please look at the examples below for a recommended syntactic style for using the find_nodes function and these nested functions.
#'
#' @param tokens  A tokenIndex data.table, created with \link{as_tokenindex}, or any data.frame with the required columns (see \link{tokenindex_columns}).
#' @param ...     used to nest the \link{parents} and \link{children} functions as unnamed arguments. See the documentation of these
#'                functions for details.
#' @param save    A character vector, specifying the column name under which the selected tokens are returned. 
#'                If NA, the column is not returned.
#' @param rel     A character vector, specifying the relation of the node to its parent. 
#' @param not_rel Like rel, but for excluding relations
#' @param select  An expression to select specific parents/children. All columns in the tokens input for \link{find_nodes} can be used, 
#'                as well as any column in the environment from which find_nodes is called. (similar to \link{subset.data.frame}).
#'                Note (!!) that select should not rely on absolute positions (i.e. choosing rows with a logical vector or a numeric vector with indices).
#' @param g_id    A data.frame or data.table with 2 columns: (1) doc_id and (2) token_id, indicating the global id. While this can also be done using 'select', this alternative uses fast binary search.
#' @param chain   The output of another find_nodes search, for chaining different queries (e.g., different ways of extracting quotes). Nodes already assigned earlier in the chain will be ignored (see 'block' argument) and results will combined (rbind) as a single data.table.  
#' @param block   Optionally, specify ids (like g_id) where find_nodes will stop (ignoring the id and recursive searches through the id). 
#'                Can also be a data.table returned by (a previous) find_nodes, in which case all ids are blocked. 
#' @param check   If TRUE, return a warning if nodes occur in multiple patterns, which could indicate that the find_nodes query is not specific enough.
#' @param e       environment used for evaluating select (used for chaining)
#'
#' @return        A data.table in which each row is a node for which all conditions are satisfied, and each column is one of the linked nodes 
#'                (parents / children) with names as specified in the save argument.
#' @export
find_nodes <- function(tokens, ..., save=NA, rel=NULL, not_rel=NULL, select=NULL, g_id=NULL, chain=NULL, block=NULL, check=T, e=parent.frame()) {
  .MATCH_ID = NULL; .DROP = NULL ## declare data.table bindings
  safe_save_name(save)
  tokens = as_tokenindex(tokens)  
  block = block_ids(block, chain)

  if (!class(substitute(select)) == 'name') select = deparse(substitute(select))
  
  
  ids = filter_tokens(tokens, rel=rel, not_rel=not_rel, select=select, g_id=g_id, block=block, e=e)
  ids = subset(ids, select = c(cname('doc_id'),cname('token_id')))
  if (length(ids) == 0) return(chain)
  ql = list(...)
  if (length(ql) > 0) {
    nodes = rec_find(tokens, ids=ids, ql=ql, e=e, block=block)
  } else {
    data.table::setnames(ids, old = cname('token_id'), new='.KEY')
    if (!is.na(save)) ids[,(save) := .KEY]
    if (!is.null(chain)) ids = rbind(chain, ids, fill=T)
    return(ids)
  }
  if (nrow(nodes) == 0) return(chain)
  
  ## always remember the node from which the search starts as .ID, for identifying unique matches
  nodes[, .KEY := .MATCH_ID]
  data.table::setcolorder(nodes, c('.KEY', setdiff(colnames(nodes), '.KEY')))
  
  if (is.na(save)) {
    nodes[,.MATCH_ID := NULL]
    data.table::setcolorder(nodes, c(cname('doc_id'),'.KEY', setdiff(colnames(nodes), c('.KEY',cname('doc_id')))))
  } else {
    if (save %in% colnames(nodes)) {
      data.table::setnames(nodes, save, paste0(save,'.y'))
      save = paste0(save,'.x')
    }
    data.table::setnames(nodes, '.MATCH_ID', save)
    data.table::setcolorder(nodes, c(cname('doc_id'),'.KEY', save, setdiff(colnames(nodes), c('.KEY',cname('doc_id'),save))))
  }
  if ('.DROP' %in% colnames(nodes)) {
    nodes[, .DROP := NULL]
  }
  
  nodes = unique(nodes)
  
  if (check) {
    lnodes = unique(melt(nodes, id.vars=c(cname('doc_id'),'.KEY'), variable.name = '.ROLE', value.name = cname('token_id')))
    if (anyDuplicated(lnodes, by=c(cname('doc_id'),cname('token_id')))) {
      warning('DUPLICATE NODES: Some tokens occur multiple times as nodes (either in different patterns or the same pattern). 
              This should be preventable by making patterns more specific. You can turn off this duplicate check by setting check to FALSE')
    }
  }
  
  data.table::setnames(nodes, colnames(nodes), gsub('\\.[xy]$', '', colnames(nodes)))
  if (!is.null(chain)) {
    nodes = if (is.null(nodes)) chain else rbind(chain, nodes, fill=T) 
  }
  nodes[]
}

#' Search for parents or children in find_nodes
#'
#' Can be used (and should only be used) inside of the \link{find_nodes} function.
#' Enables searching for parents or children, either direct (depth = 1) or untill a given depth (depth 2 for children and grandchildren, etc.).
#' The functions all_children and all_parents are shorthand for recursively retrieving all parents/children
#' 
#' Searching for parents/children within find_nodes works as an AND condition: if it is used, the node must have parents/children.
#' If select is used to pass an expression, the node must have parents/children for which the expression is TRUE.
#' The save argument can be used to remember the global token ids (.G_ID) of the parents/children under a given column name.
#'   
#' @param ...     can be used to nest other children, parents, all_children or all_parents functions, to look for grandchildren, 
#'                grandgrandchildren, etc. This is only the first argument for syntactic reasons (see details). Please see the examples for recommended syntax. 
#' @param save    A character vector, specifying the column name under which the selected tokens are returned. 
#'                If NA, the column is not returned.
#' @param rel     A character vector, specifying the allowed relations between the node and the parent/child. 
#'                If NULL, any relation is allowed. This is different from selecting on the relation column with the select argument, 
#'                because it take into account that when you look for parents, the relation column of the current node should be used 
#'                instead of the relation column of the parent node. In addition, use rel is faster because it uses binary search.
#'                Note that if depth > 1 (or if all_parents/all_children are used), rel is only used for the first parent/child.
#'                In this case, it makes more sense for syntactical clarity to first look for only the direct parent/child and then nest 
#'                another (all_)parents/children search. 
#' @param not_rel Like rel, but for excluding relations.
#' @param select  An expression to select specific parents/children. All columns in the tokens input for \link{find_nodes} can be used, 
#'                as well as any column in the environment from which find_nodes is called. (similar to \link{subset.data.frame}).
#'                Note (!!) that select will be performed on the children only (i.e. a subset of the tokenIndex) and thus should not rely on
#'                absolute positions. For instance, do not use a logical vector unless it is a column in the tokenIndex.
#' @param g_id    A numeric vector, to filter on global id (.G_ID). While this can also be done using 'select', this alternative uses fast binary search.
#' @param NOT     If TRUE, exclude these children instead of adding them. The filter parameters still work to NOT select specific children.             
#' @param depth   A positive integer, determining how deep parents/children are sought. The default, 1, 
#'                means that only direct parents and children of the node are retrieved. 2 means children and grandchildren, etc.
#'                In all_children and all_parents, the depth is set to Inf (infinite)
#'
#' @details 
#' Having nested queries can be confusing, so we tried to develop the find_nodes function and the accompanying functions in a way
#' that clearly shows the different levels. As shown in the examples, the idea is that each line is a node, and to look for parents
#' or children, we put them on the next line with indentation (in RStudio, it should automatically allign correctly when you press enter inside
#' of the children() or parents() functions). 
#' 
#' @return Should not be used outside of \link{find_nodes}
#' @name find_nodes_functions
#' @rdname find_nodes_functions
NULL

#' @rdname find_nodes_functions
#' @export
children <- function(..., save=NA, rel=NULL, not_rel=NULL, select=NULL, g_id=NULL, NOT=F, depth=1) {
  list(rel=rel, not_rel=not_rel, select = deparse(substitute(select)), g_id=g_id, save=save, nested = list(...),
       level = 'children', NOT=NOT, depth=depth)
}

#' @rdname find_nodes_functions
#' @export
all_children <- function(..., save=NA, rel=NULL, not_rel=NULL, select=NULL, g_id=NULL, NOT=F) {
  list(rel=rel, not_rel=not_rel, select = deparse(substitute(select)), g_id=g_id, save=save, nested = list(...),
       level = 'children', NOT=NOT, depth=Inf)
}

#' @rdname find_nodes_functions
#' @export
parents <- function(..., save=NA, rel=NULL, not_rel=NULL, select=NULL, g_id=NULL, NOT=F, depth=1) {
  list(rel=rel, not_rel=not_rel, select = deparse(substitute(select)), g_id=g_id, save=save, nested = list(...),
       level = 'parents', NOT=NOT, depth=depth)
}

#' @rdname find_nodes_functions
#' @export
all_parents <- function(..., save=NA, rel=NULL, not_rel=NULL, select=NULL, g_id=NULL, NOT=F) {
  list(rel=rel, not_rel=not_rel, select = deparse(substitute(select)), g_id=g_id, save=save, nested = list(...),
       level = 'parents', NOT=NOT, depth=Inf)
}

#' Get and/or merge ids for the block argument in \link{find_nodes}
#'
#' @param ... Either a data.table with the columns doc_id and token_id, or the output of \link{find_nodes}
#'
#' @return A data.table with the columns doc_id and token_id
#' @export
block_ids <- function(...) {
  l = list(...)
  len = length(l)
  out = vector('list', len)
  for (i in 1:len) {
    d = l[[i]]
    if (is.null(d)) next
    if (is(d, 'data.table')) {
      if (!cname('token_id') %in% colnames(d)) {
        d = d[,c(cname('doc_id'), '.KEY')]
        data.table::setnames(d, '.KEY', cname('token_id'))
      } 
      out[[i]] = d[,c(cname('doc_id'),cname('token_id'))]
      next
    }
    if (is(d, 'list')) {
      out[[i]] = block_ids(d)
    }
    print(d)
    stop('Not a valid input for block_ids')
  }
  out = unique(data.table::rbindlist(out))
  if (ncol(out) == 0) NULL else out
}


rec_find <- function(tokens, ids, ql, e=parent.frame(), block=NULL) {
  out = data.table::data.table()
  for (i in seq_along(ql)) {
    q = ql[[i]]
    
    if (is.na(q$save)) {
      q$save = '.DROP'
    } else {
      safe_save_name(q$save)
    }
    
    selection = select_tokens(tokens, ids=ids, q=q, e=e, block=block)
    if (length(q$nested) > 0 & length(selection) > 0) {
      nested = rec_find(tokens, ids=selection[,c(cname('doc_id'),q$save),with=F], ql=q$nested, e=e, block=block)  
      ## The match_id column in nested (y) is used to match nested results to the current level
      ## after merging, the .MATCH_ID column in selection (x) remains, so we can use this to match
      ## selection to other selections at the same level (merge with out) and the higher level
      if (nrow(nested) > 0) {
        selection = merge(selection, nested, by.x=c(cname('doc_id'),q$save), by.y=c(cname('doc_id'),'.MATCH_ID'), allow.cartesian=T) 
      } else {
        selection = data.table::data.table(.MATCH_ID = numeric(), doc_id=numeric(), .DROP = numeric())
        data.table::setnames(selection, 'doc_id', cname('doc_id'))
      }
    } 
    data.table::setkeyv(selection, c(cname('doc_id'),'.MATCH_ID'))
  
    if (q$NOT) {
      selection = data.table::fsetdiff(data.table(ids[,1], .MATCH_ID=ids[[2]]), selection[,c(cname('doc_id'),'.MATCH_ID')])
      selection[,.DROP := NA]
    }
    if (nrow(selection) == 0) return(selection)
    out = if(nrow(out) > 0) merge(out, selection, by=c(cname('doc_id'),'.MATCH_ID'), allow.cartesian=T) else selection
  }
  out
}


select_tokens <- function(tokens, ids, q, e, block=NULL) {
  .MATCH_ID = NULL ## bindings for data.table

  selection = token_family(tokens, ids=ids, rel=q$rel, not_rel=q$not_rel, level=q$level, depth=q$depth, block=block, replace=T)
  
  if (!data.table::haskey(selection)) data.table::setkeyv(selection, c(cname('doc_id'),cname('token_id')))
  selection = filter_tokens(selection, g_id = q$g_id, select=q$select)
  
  selection = subset(selection, select=c('.MATCH_ID', cname('doc_id'),cname('token_id')))
  data.table::setnames(selection, cname('token_id'), q$save)
  selection
}


filter_tokens <- function(tokens, rel=NULL, not_rel=NULL, select='NULL', g_id=NULL, g_parent=NULL, block=NULL, e=parent.env()) {
  if (!is.null(rel)) tokens = tokens[list(rel), on=cname('relation'), nomatch=0]
  if (!is.null(not_rel)) tokens = tokens[!list(not_rel), on=cname('relation')]
  if (!is.null(g_id)) tokens = tokens[list(g_id[[1]], g_id[[2]]), on=c(cname('doc_id'),cname('token_id')), nomatch=0]
  if (!is.null(g_parent)) tokens = tokens[list(g_parent[[1]], g_parent[[2]]), on=c(cname('doc_id'),cname('parent')), nomatch=0]
  block = block_ids(block)
  if (!is.null(block)) tokens = tokens[!list(block[[1]], block[[2]]), on=c(cname('doc_id'),cname('token_id'))]
  if (!select == 'NULL' & !is.null(select)) tokens = tokens[eval(parse(text=select), tokens, e),]
  tokens
}

token_family <- function(tokens, ids, rel=NULL, not_rel=NULL, level='children', depth=Inf, minimal=F, block=NULL, replace=F) {
  .MATCH_ID = NULL
  if (!replace) block = block_ids(ids, block)
  if ('.MATCH_ID' %in% colnames(tokens)) tokens[, .MATCH_ID := NULL]

  if (level == 'children') {
    id = tokens[list(ids[[1]], ids[[2]]), on=c(cname('doc_id'),cname('parent')), nomatch=0]
    id = filter_tokens(id, rel=rel, not_rel=not_rel, block=block)
    if (minimal) id = subset(id, select = c(cname('doc_id'),cname('token_id'),cname('parent'),cname('relation')))
    data.table::set(id, j = '.MATCH_ID', value = id[[cname('parent')]])
  }
  if (level == 'parents') {
    .NODE = filter_tokens(tokens, g_id = ids, rel=rel, not_rel=not_rel)
    .NODE = subset(.NODE, select=c(cname('doc_id'),cname('parent'),cname('token_id')))

    data.table::setnames(.NODE, old=cname('token_id'), new='.MATCH_ID')
    id = filter_tokens(tokens, g_id = .NODE[,c(cname('doc_id'),cname('parent'))], block=block)
    if (minimal) id = subset(id, select = c(cname('doc_id'),cname('token_id'),cname('parent'),cname('relation')))
    id = merge(id, .NODE, by.x=c(cname('doc_id'),cname('token_id')), by.y=c(cname('doc_id'),cname('parent')), allow.cartesian=T)
  }
  
  if (depth > 1) id = deep_family(tokens, id, level, depth, minimal=minimal, block=block, replace=replace) 
  id
}

deep_family <- function(tokens, id, level, depth, minimal=F, block=NULL, replace=F) {
  id_list = vector('list', 20) 
  id_list[[1]] = id
  i = 2
  while (i <= depth) {
    .NODE = id_list[[i-1]]
    if (!replace) block = block_ids(block, .NODE[,cname('doc_id','token_id'), with=F])
    
    if (level == 'children') {
      id = filter_tokens(tokens, g_parent = .NODE[,c(cname('doc_id'),cname('token_id'))], block=block)
      id = merge(id, subset(.NODE, select = c(cname('doc_id'),cname('token_id'),'.MATCH_ID')), by.x=c(cname('doc_id'),cname('parent')), by.y=c(cname('doc_id'),cname('token_id')), allow.cartesian=T)
      id_list[[i]] = if (minimal) subset(id, select = c(cname('doc_id'),cname('token_id'),cname('parent'),cname('relation'),'.MATCH_ID')) else id
    }
  
    if (level == 'parents') {
      id = filter_tokens(tokens, g_id = .NODE[,c(cname('doc_id'),cname('parent'))], block=block)
      id = merge(id, subset(.NODE, select = c(cname('doc_id'),cname('parent'), '.MATCH_ID')), by.x=c(cname('doc_id'),cname('token_id')), by.y=c(cname('doc_id'),cname('parent')), allow.cartesian=T)
      id_list[[i]] = if (minimal) subset(id, select = c(cname('doc_id'),cname('token_id'),cname('parent'),cname('relation'),'.MATCH_ID')) else id
    }
    if (nrow(id_list[[i]]) == 0) break
    i = i + 1
  }
  data.table::rbindlist(id_list)
}

safe_save_name <- function(name) {
  if(grepl('\\.[A-Z]', name)) stop(sprintf('save name cannot be all-caps and starting with a dot'))
  special_names = cname('doc_id','token_id')
  if (name %in% special_names) stop(sprintf('save name (%s) cannot be the same as the special tokenIndex column names (%s)', name, paste(special_names, collapse=', ')))
}




function(){
  
#find_nodes(tokens, id ~ lemma %in% .VIND_VERBS, 
#           children(source ~ 'su' ~ ),
#           children(quote ~ relation == tada & pos == 'comp',
#                    children(~ relation == 'body')))
  
data("example_tokens_dutchquotes")
  
tracemem(tokens)  
tokens = data.table::data.table(tokens) ## makes copies
tokens = as_tokenindex(tokens, 'aid','id',cname('parent'),cname('relation')) ## makes no additional copies

test <- function(tokens) {
  
  tada = 'vc'
  find_nodes(tokens, select = lemma %in% .VIND_VERBS,
             children(save = 'syntax', rel='su'),
             children(save = 'tree', rel=tada, select = POS == 'comp',
                      children(save='lookup', rel='body')))
  
  nodes = find_nodes(tokens, save = 'test', select = lemma %in% .VIND_VERBS,
             children(save = 'syntax', rel='su'),
             children(save = 'tree',
                      children(save='lookup')))
  
  find_nodes(tokens, save='test', select = lemma == 'Rutte',
             parents(save='papa', rel='su', select=NULL,
                     children(save='nephew')))
  
  find_nodes(tokens, save='test', select=.G_ID == 1,
             parents(save='2', select=.G_ID == 2,
                     parents(save='papa', rel='su', select=NULL,
                              children(save='nephew'))))
  
  
  find_nodes(tokens, save='id', select = lemma %in% .VIND_VERBS,
             children(save='specific', rel='su'),
             children(save='all'))
  
  find_nodes(tokens, save='id', select = lemma %in% .VIND_VERBS,
             children(save='all'),
             children(save='specific', rel='su'))
  
  
  nodes = find_nodes(tokens, save='id', select = lemma %in% .VIND_VERBS,
             children(save = 'source', rel='su'),
             children(rel='vc', select = pos == 'comp',
                      children(save='quote', rel='body')))
  nodes
  
  find_nodes(tokens, save='test', select = lemma %in% .VIND_VERBS, block=nodes)
  
  find_nodes(tokens, save='root',
             children(save = 'test', rel='su'))
  head(tokens, 10)
  
  nodes = find_nodes(tokens, save='x', select=.G_ID %in% c(2,7,8),
             children(save='y'))
  nodes
  
  out = find_nodes(tokens, save='child', select = .G_ID %in% c(7,8), 
                   parents(save=cname('parent')))
  out
  annotate(tokens, nodes, 'test')
  annotate(tokens, nodes, 'test', use=c('source','quote'))
  
}


tokens = as_tokenindex(tokens_dutchquotes)

}