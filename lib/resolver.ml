open Yocaml

type t = 
  { source: Path.t
  ; target: Path.t
  ; server: Path.t
  }

let make 
  ?(source_folder = Path.rel [])
  ?(target_folder = Path.rel ["_www"])
  ?(server_folder = Path.abs []) 
  () 
  = 
  { source = source_folder
  ; target = target_folder
  ; server = server_folder
  }

module Source = struct 
  let source_root { source; _ } = source

  (* Assets *)
  let assets res = Path.(source_root res / "assets")
  let images res = Path.(assets res / "images")
  let css res = Path.(assets res / "css")
  let templates res = Path.(assets res / "templates")
  
  (* Content *)
  let content res = Path.(source_root res / "content")
  let pages res = Path.(content res / "pages")
  let articles res = Path.(content res / "articles")
  let experiences res = Path.(content res / "experiences")
  let education res = Path.(content res / "education")
  let index res = Path.(content res / "index.md")
  let blog res = Path.(content res / "blog.md")
  let cv res = Path.(content res / "cv.md")
  let site res = Path.(content res / "site.yml")

end

module Target = struct 
  let target_root { target; server; _ } = 
    Path.relocate ~into:target server
    
  let cache res = 
    Path.(target_root res / ".cache")
    
  let images res = 
    Path.(target_root res / "images")
    
  let style_css res = 
    Path.(target_root res / "style.css")
    
 
  let page res source = 
    let into = target_root res in
    source 
    |> Path.move ~into
    |> Path.change_extension "html"
    
  let article res source = 
    let into = Path.(target_root res / "articles") in
    source 
    |> Path.move ~into
    |> Path.change_extension "html"
    
  let index res = 
    Path.(target_root res / "index.html")

  let cv res =
    Path.(target_root res / "cv.html")
  
  let blog res = 
    Path.(target_root res / "blog.html")
    
  let atom res = 
    Path.(target_root res / "atom.xml")
end

module Server = struct 
  let server_root { server; _ } = server
  
  let from_target res path = 
    let prefix = Target.target_root res in
    let into = server_root res in
    path 
    |> Path.trim ~prefix 
    |> Path.relocate ~into
end