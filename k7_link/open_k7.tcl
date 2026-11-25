# Open the hw_server target that holds the xc7k325t (the server may expose other cables/boards).
proc open_k7 {url} {
  open_hw_manager
  connect_hw_server -url $url
  foreach t [get_hw_targets] {
    open_hw_target $t
    set dev [lindex [get_hw_devices -quiet xc7k325t*] 0]
    if {$dev ne ""} { current_hw_device $dev; puts "K7 on target $t"; return $dev }
    close_hw_target $t
  }
  error "No xc7k325t on any JTAG target of $url"
}
