@ledger.wallet ?= {}

class ledger.wallet.HDWallet

  getAccount: (accountIndex) -> @_accounts[accountIndex]

  getAccountFromDerivationPath: (derivationPath) ->
    return null unless derivationPath?
    account = null
    # Easy way
    if _.str.startsWith(derivationPath, "44'")
      parts = derivationPath.split(',')
      accountIndex = parts[2]
      if accountIndex?
        accountIndex = parseInt(accountIndex.substr(0, accountIndex.length - 1))
        account = @getAccount(accountIndex)

    return account if account?
    # Crappy way
    for account in @_accounts
      return account if _.contains(account.getAllChangeAddressesPaths(), derivationPath)
      return account if _.contains(account.getAllPublicAddressesPaths(), derivationPath)

  getAccountFromAddress: (address) -> @getAccountFromDerivationPath(@cache?.getDerivationPath(address))

  createAccount: () ->
    account = new ledger.wallet.HDWallet.Account(@, @getAccountsCount(), @_store)
    @_accounts.push account
    do @save
    account

  getOrCreateAccount: (id) ->
    return @getAccount(id) if @getAccount(id)
    do @createAccount

  initialize: (store, callback) ->
    @_store = store
    console.log("Going to get acounts")
    @_store.get ['accounts'], (result) =>
      console.log("Accounts result", result)
      @_accounts = []
      return callback?() unless result.accounts?
      _.async.each [0...result.accounts], (accountIndex, done, hasNext) =>
        try
          account = new ledger.wallet.HDWallet.Account(@, accountIndex, @_store)
          account.initialize () =>
            @_accounts.push account
            done?()
            callback?() unless hasNext
        catch er
          e er

  release: () ->
    account.release() for account in @_accounts
    @_accounts = null
    @cache = null

  isEmpty: () -> @_accounts?.length == 0

  isInitialized: no

  getRootDerivationPath: () -> "44'/0'"

  getAccountsCount: () -> @_accounts.length

  save: (callback = _.noop) ->
    @_store.set {'accounts': @getAccountsCount()}, callback

  @instance: undefined

class ledger.wallet.HDWallet.Account

  constructor: (dongle, index, store) ->
    @dongle = dongle
    @index = index
    @_store = store
    @_storeId = "account_#{@index}"
    @_initialize()

  _initialize: () ->
    @_account ?= {}
    @_account.currentChangeIndex ?= 0
    @_account.currentPublicIndex ?= 0

  initializeXpub: (callback) ->
    ledger.app.dongle.getExtendedPublicKey "#{@dongle.getRootDerivationPath()}/#{@index}'", (xpub) =>
      @_xpub = xpub
      callback?()

  initialize: (callback) ->
    console.log("Going to get #{[@_storeId]}")
    @_store.get [@_storeId], (result) =>
      console.log("Get result", result)
      @_account = result[@_storeId]
      @_initialize()
      @initializeXpub callback

  release: () ->
    @dongle = null
    @_store = null
    @_storeId = null
    @index = null

  getAllChangeAddressesPaths: () ->
    paths = []
    paths = paths.concat(@_account.importedChangePaths)
    for index in [0..@_account.currentChangeIndex]
      paths.push "#{@dongle.getRootDerivationPath()}/#{@index}'/1/#{index}"
    paths = _.difference(paths, @_account.excludedChangePaths)
    paths
    _(paths).without(undefined)

  getAllPublicAddressesPaths: () ->
    paths = []
    paths = paths.concat(@_account.importedPublicPaths)
    for index in [0..@_account.currentPublicIndex]
      paths.push "#{@dongle.getRootDerivationPath()}/#{@index}'/0/#{index}"
    paths = _.difference(paths, @_account.excludedPublicPaths)
    _(paths).without(undefined)

  getAllAddressesPaths: () -> @getAllPublicAddressesPaths().concat(@getAllChangeAddressesPaths())

  getCurrentPublicAddressIndex: () -> @_account.currentPublicIndex or 0
  getCurrentChangeAddressIndex: () -> @_account.currentChangeIndex or 0
  getCurrentAddressIndex: (type) ->
    switch type
      when 'change' then @getChangeAddressPath(index)
      when 'public' then @getPublicAddressPath(index)

  getCurrentPublicAddressPath: () -> @getPublicAddressPath(@getCurrentPublicAddressIndex())
  getCurrentChangeAddressPath: () -> @getChangeAddressPath(@getCurrentChangeAddressIndex())
  getCurrentAddressPath: (type) ->
    switch type
      when 'change' then @getCurrentChangeAddressPath(index)
      when 'public' then @getCurrentPublicAddressPath(index)


  getPublicAddressPath: (index) -> "#{@dongle.getRootDerivationPath()}/#{@index}'/0/#{index}"
  getChangeAddressPath: (index) -> "#{@dongle.getRootDerivationPath()}/#{@index}'/1/#{index}"
  getAddressPath: (index, type) ->
    switch type
      when 'change' then @getChangeAddressPath(index)
      when 'public' then @getPublicAddressPath(index)

  getCurrentChangeAddress: () -> @dongle.cache?.get(@getCurrentChangeAddressPath())
  getCurrentPublicAddress: () -> @dongle.cache?.get(@getCurrentPublicAddressPath())

  notifyPathsAsUsed: (paths) ->
    paths = [paths] unless _.isArray(paths)
    for path in paths
      path = path.replace("#{@dongle.getRootDerivationPath()}/0'/", '').split('/')
      switch path[0]
        when '0' then @_notifyPublicAddressIndexAsUsed parseInt(path[1])
        when '1' then @_notifyChangeAddressIndexAsUsed parseInt(path[1])
    return

  _notifyPublicAddressIndexAsUsed: (index) ->
    l 'Notify public change', index, 'current is', @_account.currentPublicIndex
    if index < @_account.currentPublicIndex
      l 'Index is less than current'
      derivationPath = "#{@dongle.getRootDerivationPath()}/#{@index}'/0/#{index}"
      @_account.excludedPublicPaths = _.without @_account.excludedPublicPaths, derivationPath
    else if index > @_account.currentPublicIndex
      l 'Index is more than current'
      difference =  index - (@_account.currentPublicIndex + 1)
      @_account.excludedPublicPaths ?= []
      for i in [0...difference]
        derivationPath = "#{@dongle.getRootDerivationPath()}/#{@index}'/0/#{index - i - 1}"
        @_account.excludedPublicPaths.push derivationPath unless _.contains(@_account.excludedPublicPaths, derivationPath)
      @_account.currentPublicIndex = parseInt(index) + 1
    else if index == @_account.currentPublicIndex
        l 'Index is equal to current'
        @shiftCurrentPublicAddressPath()
    @save()

  _notifyChangeAddressIndexAsUsed: (index) ->
    if index < @_account.currentChangeIndex
      derivationPath = "#{@dongle.getRootDerivationPath()}/#{@index}'/1/#{index}"
      @_account.excludedChangePaths = _.without @_account.excludedChangePaths, derivationPath
    else if index > @_account.currentChangeIndex
      difference =  index - (@_account.currentChangeIndex + 1)
      @_account.excludedChangePaths ?= []
      for i in [0...difference]
        derivationPath = "#{@dongle.getRootDerivationPath()}/#{@index}'/1/#{index - i - 1}"
        @_account.excludedChangePaths.push derivationPath unless _.contains(@_account.excludedChangePaths, derivationPath)
      @_account.currentChangeIndex = parseInt(index) + 1
    else if index == @_account.currentChangeIndex
      @shiftCurrentChangeAddressPath()
    @save()

  shiftCurrentPublicAddressPath: (callback) ->
    l 'shift public'
    index = @_account.currentPublicIndex
    index = 0 unless index?
    index = parseInt(index) if _.isString(index)
    @_account.currentPublicIndex = index + 1
    @save()
    ledger.app.dongle?.getPublicAddress @getCurrentPublicAddressPath(), callback

  shiftCurrentChangeAddressPath: (callback) ->
    l 'shift change'
    index = @_account.currentChangeIndex
    index = 0 unless index?
    index = parseInt(index) if _.isString(index)
    @_account.currentChangeIndex = index + 1
    @save()
    ledger.app.dongle?.getPublicAddress @getCurrentChangeAddressPath(), callback

  importPublicAddressPath: (addressPath) ->
    @_account.importedPublicPaths ?= []
    @_account.importedPublicPaths.push addressPath

  importChangeAddressPath: (addressPath) ->
    @_account.importedChangePaths ?= []
    @_account.importedChangePaths.push addressPath

  save: (callback = _.noop) ->
    saveHash = {}
    saveHash[@_storeId] = @_account
    @_store.set saveHash, callback

openStores = (dongle, done) ->
  console.log("Going to openStores")
  Try =>
    dongle.getBitIdAddress (address) =>
      Try =>
        bitIdAddress = address.bitcoinAddress.value
        dongle.getPublicAddress "0x50DA'/0xBED'/0xC0FFEE'", (pubKey) =>
          Try =>
            if not (pubKey?.bitcoinAddress?) or not (bitIdAddress?)
              console.error("Fatal error during openStores, missing bitIdAddress and/or pubKey.bitcoinAddress")
              ledger.app.emit 'wallet:initialization:fatal_error'
              return
            ledger.storage.openStores bitIdAddress, pubKey.bitcoinAddress.value
            console.log("Done openStores")
            done?()
          .printError()
      .printError()
  .printError()

openHdWallet = (dongle, done) ->
  console.log("Going to openHdWallet")
  Try =>
    hdWallet = new ledger.wallet.HDWallet()
    hdWallet.initialize ledger.storage.wallet, () =>
      console.log("HdWallet initialized")
      Try =>
        ledger.wallet.HDWallet.instance = hdWallet
        ledger.tasks.AddressDerivationTask.instance.start()
        _.defer =>
          Try =>
            for accountIndex in [0...hdWallet.getAccountsCount()]
              ledger.tasks.AddressDerivationTask.instance.registerExtendedPublicKeyForPath "#{hdWallet.getRootDerivationPath()}/#{accountIndex}'", _.noop
            console.log("Done openHdWallet")
            done?()
          .printError()
      .printError()
  .printError()

openAddressCache = (dongle, done) ->
  console.log("Going to openAddressCache")
  cache = new ledger.wallet.HDWallet.Cache(ledger.wallet.HDWallet.instance)
  cache.initialize =>
    ledger.wallet.HDWallet.instance.cache = cache
    console.log("Done openAddressCache")
    done?()

restoreStructure = (dongle, done) ->
  console.log("Going to restoreStructure")
  if ledger.wallet.HDWallet.instance.isEmpty()
    ledger.app.emit 'wallet:initialization:creation'
    ledger.tasks.WalletLayoutRecoveryTask.instance.on 'done', () =>
      console.log("Done restoreStructure")
      done?()
    ledger.tasks.WalletLayoutRecoveryTask.instance.on 'fatal_error', () =>
      ledger.storage.local.clear()
      ledger.app.emit 'wallet:initialization:failed'
    ledger.tasks.WalletLayoutRecoveryTask.instance.startIfNeccessary()
  else
    ledger.tasks.WalletLayoutRecoveryTask.instance.startIfNeccessary()
    console.log("Done restoreStructure")
    done?()

completeInitialization = (dongle, done) ->
  console.log("Going to completeInitialization")
  ledger.wallet.HDWallet.instance.isInitialized = yes
  console.log("Done completeInitialization")
  done?()

_.extend ledger.wallet,

  initialize: (dongle, callback=undefined) ->
    intializationMethods = [openStores, openHdWallet, openAddressCache, restoreStructure, completeInitialization]
    _.async.each intializationMethods, (method , done, hasNext) =>
      method(dongle, done)
      callback?() unless hasNext

  release: (dongle, callback) ->
    ledger.storage.closeStores()
    ledger.wallet.HDWallet.instance?.release()
    ledger.wallet.HDWallet.instance = null