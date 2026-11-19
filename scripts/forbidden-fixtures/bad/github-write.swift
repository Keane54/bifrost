let text = "mutation Reply($thread: ID!) { x }"
let field = "resolveReviewThread"
let block = """
    query A { a }
    addComment(input: {})
    """
let raw = #"{"query": "mutation { x }"}"#
