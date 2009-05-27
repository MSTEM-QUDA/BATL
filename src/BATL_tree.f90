module BATL_tree

  use BATL_size, ONLY: MaxBlock, nBlock, MaxDim, nDimTree

  implicit none
  save

  private ! except

  public:: init_tree
  public:: clean_tree
  public:: set_tree_root
  public:: refine_tree_node
  public:: coarsen_tree_node
  public:: get_tree_position
  public:: find_tree_node
  public:: distribute_tree
  public:: write_tree_file
  public:: read_tree_file
  public:: show_tree
  public:: test_tree

  integer, public, parameter :: nChild = 2**nDimTree

  integer, public, allocatable :: iTree_IA(:,:)

  integer, public, parameter :: &
       Status_   =  1, &
       Level_    =  2, &
       Proc_     =  3, &
       Block_    =  4, &
       ProcNew_  =  5, &
       BlockNew_ =  6, &
       Coord0_   =  6, &
       Coord1_   =  7, &
       CoordLast_=  9, &
       Parent_   = 10, & ! Parent must be just before the first child!
       Child0_   = 10, &
       Child1_   = Child0_ + 1,      &
       ChildLast_= Child0_ + nChild

  ! Number of items stored in iTree_IA
  integer, parameter :: nInfo = ChildLast_

  character(len=10), parameter:: NameTreeInfo_I(Child0_+8) = (/ &
       'Status   ', &
       'Level    ', &
       'Proc     ', &
       'Block    ', &
       'ProcNew  ', &
       'BlockNew ', &
       'Coord1   ', &
       'Coord2   ', &
       'Coord3   ', &
       'Parent   ', &
       'Child1   ', &
       'Child2   ', &
       'Child3   ', &
       'Child4   ', &
       'Child5   ', &
       'Child6   ', &
       'Child7   ', &
       'Child8   ' /)

  ! Mapping from local block and processor index to global node index
  integer, public, allocatable :: iNode_BP(:,:)

  ! Unused blocks
  logical, public, allocatable :: Unused_B(:)

  ! Local variables -----------------------------------------------

  ! Deepest AMR level relative to root nodes (limited by 32 bit integers)
  integer, parameter :: MaxLevel = 30

  ! The maximum integer coordinate for a given level below root nodes
  ! The loop variable has to be declared to work-around NAG f95 bug
  integer :: L__
  integer, parameter :: &
       MaxCoord_I(0:MaxLevel) = (/ (2**L__, L__=0,MaxLevel) /)

  ! The number of root nodes in all dimensions, and altogether
  integer :: nRoot_D(MaxDim) = 0, nRoot = 0

  character(len=*), parameter:: NameMod = "BATL_tree"

  integer, parameter :: UnitTmp_ = 9 ! same as used in SWMF

  ! Possible values for the status variable
  integer, parameter :: Unused_=1, Used_=2, Refine_=3, Coarsen_=4

  ! Index for unset values (that are otherwise larger)
  integer, parameter :: Unset_ = -100

  ! Neighbor information
  integer, allocatable :: DiLevelNei_IIIB(:,:,:,:), iNodeNei_IIIB(:,:,:,:)

  ! Maximum number of nodes including unused and skipped ones
  integer :: MaxNode = 0

  ! Number of used nodes (leaves of the node tree)
  integer :: nNodeUsed = 0

  ! Number of nodes in the tree (some may not be used)
  integer :: nNode = 0

  ! Number of levels below root in level (that has occured at any time)
  integer :: nLevel = 0

  ! Periodicity of the domain per dimension
  logical :: IsPeriodic_D(MaxDim) = .false.

  ! Cylindrical or spherical coordinates
  logical :: IsSpherical = .false., IsCylindrical = .false.

  ! Ordering along the Peano-Hilbert space filling curve
  integer, allocatable :: iNodePeano_I(:)

  ! The index along the Peano curve is global so that it can be used by the 
  ! recursive subroutine order_children 
  integer :: iPeano

contains

  subroutine init_tree(MaxBlockIn, MaxNodeIn)

    use BATL_mpi, ONLY: nProc

    ! Initialize the tree array with nNode nodes

    integer, intent(in) :: MaxBlockIn ! Max number of blocks per processor
    integer, intent(in) :: MaxNodeIn  ! Max number of nodes altogether
    !----------------------------------------------------------------------
    if(allocated(iTree_IA)) RETURN

    ! Store tree size and maximum number of blocks/processor
    MaxNode = MaxNodeIn
    MaxBlock = MaxBlockIn

    ! Allocate and initialize all elements of tree as unset
    allocate(iTree_IA(nInfo, MaxNode));                iTree_IA        = Unset_
    allocate(iNodePeano_I(MaxNode));                   iNodePeano_I    = Unset_
    allocate(iNode_BP(MaxBlock,0:nProc-1));            iNode_BP        = Unset_
    allocate(Unused_B(MaxBlock));                      Unused_B        =.true.
    allocate(iNodeNei_IIIB(0:3,0:3,0:3,MaxBlock));     iNodeNei_IIIB   = Unset_
    allocate(DiLevelNei_IIIB(-1:1,-1:1,-1:1,MaxBlock));DiLevelNei_IIIB = Unset_

  end subroutine init_tree

  !==========================================================================
  subroutine clean_tree

    if(.not.allocated(iTree_IA)) RETURN
    deallocate(iTree_IA, iNodePeano_I, iNode_BP, Unused_B, &
         iNodeNei_IIIB, DiLevelNei_IIIB)

    MaxNode = 0

  end subroutine clean_tree
  !==========================================================================

  integer function i_node_new()

    ! Find a skipped element in the iTree_IA array

    integer :: iNode

    do iNode = 1, MaxNode
       if(iTree_IA(Status_, iNode) == Unset_)then
          i_node_new = iNode
          RETURN
       end if
    end do
    ! Could not find any skipped node
    i_node_new = -1

  end function i_node_new

  !==========================================================================

  subroutine set_tree_root(nRootIn_D, IsPeriodicIn_D)

    integer, intent(in) :: nRootIn_D(MaxDim)
    logical, intent(in) :: IsPeriodicIn_D(MaxDim)

    integer :: iRoot, jRoot, kRoot, iNode, Ijk_D(MaxDim)
    !-----------------------------------------------------------------------

    nRoot_D      = nRootIn_D
    nRoot        = product(nRoot_D)
    IsPeriodic_D = IsPeriodicIn_D

    ! Use the first product(nRoot_D) nodes as root nodes in the tree
    iNode = 0
    do kRoot = 1, nRoot_D(3)
       do jRoot = 1, nRoot_D(2)
          do iRoot = 1, nRoot_D(1)

             Ijk_D = (/ iRoot, jRoot, kRoot /)

             iNode = iNode + 1
             iTree_IA(Status_, iNode)            = Used_
             iTree_IA(Parent_, iNode)            = Unset_
             iTree_IA(Child1_:ChildLast_, iNode) = Unset_
             iTree_IA(Level_ , iNode)            = 0
             iTree_IA(Coord1_:CoordLast_, iNode) = Ijk_D

          end do
       end do
    end do

    nNodeUsed = nRoot
    nNode     = nRoot

    ! Set neighbor info
    !do iNode = 1, nRoot
    !   call find_neighbors(iNode)
    !end do

  end subroutine set_tree_root

  !==========================================================================
  subroutine refine_tree_node(iNode)

    integer, intent(in) :: iNode

    integer :: iChild, DiChild, iLevelChild, iProc, iBlock
    integer :: iCoord_D(nDimTree)
    integer :: iDim, iNodeChild
    !----------------------------------------------------------------------

    iTree_IA(Status_, iNode) = Unused_

    iLevelChild = iTree_IA(Level_, iNode) + 1
    iProc       = iTree_IA(Proc_,  iNode)
    iBlock      = iTree_IA(Block_, iNode)

    ! Keep track of number of levels
    nLevel = max(nLevel, iLevelChild)
    if(nLevel > MaxLevel) &
         call CON_stop('Error in refine_tree_node: too many levels')

    iCoord_D = 2*iTree_IA(Coord1_:Coord0_+nDimTree, iNode) - 1

    do iChild = Child1_, ChildLast_

       iNodeChild = i_node_new()

       iTree_IA(iChild, iNode) = iNodeChild

       iTree_IA(Status_,   iNodeChild) = Used_
       iTree_IA(Level_,    iNodeChild) = iLevelChild
       iTree_IA(Parent_,   iNodeChild) = iNode
       iTree_IA(Child1_:ChildLast_, iNodeChild) = Unset_

       ! This overwrites the two first children (saves memory)
       iTree_IA(Proc_,     iNodeChild) = iProc
       iTree_IA(Block_,    iNodeChild) = iBlock

       ! Calculate the coordinates of the child node
       DiChild = iChild - Child1_
       do iDim = 1, nDimTree
          iTree_IA(Coord0_+iDim, iNodeChild) = &
               iCoord_D(iDim) + ibits(DiChild, iDim-1, 1)
       end do

       ! The non-AMR coordinates remain the same as for the parent node
       do iDim = nDimTree+1, MaxDim
          iTree_IA(Coord0_+iDim, iNodeChild) = iTree_IA(Coord0_+iDim, iNode)
       end do

    end do

    nNodeUsed = nNodeUsed + nChild - 1

    ! Find neighbors of children
    !do iChild = Child1_, ChildLast_
    !
    !   iNodeChild = iTree_IA(iChild, iNode)
    !   call find_neighbors(iNodeChild)
    !
    !end do

    ! Should also redo neighbors of the parent node

  end subroutine refine_tree_node

  !==========================================================================
  subroutine coarsen_tree_node(iNode)

    integer, intent(in) :: iNode

    integer :: iChild, iNodeChild1, iNodeChild
    !-----------------------------------------------------------------------

    do iChild = Child1_, ChildLast_
       iNodeChild = iTree_IA(iChild, iNode)

       ! Wipe out the child node
       iTree_IA(Status_, iNodeChild) = Unset_
    end do

    ! Make this node used with no children
    iTree_IA(Status_, iNode) = Used_

    iNodeChild1 = iTree_IA(Child1_, iNode)
    iTree_IA(Child1_:ChildLast_, iNode) = Unset_

    ! set proc and node info from child1
    iTree_IA(Proc_,  iNode) = iTree_IA(Proc_,  iNodeChild1)
    iTree_IA(Block_, iNode) = iTree_IA(Block_, iNodeChild1)

    nNodeUsed = nNodeUsed - nChild + 1

  end subroutine coarsen_tree_node

  !==========================================================================
  subroutine get_tree_position(iNode, PositionMin_D, PositionMax_D)

    integer, intent(in) :: iNode
    real,    intent(out):: PositionMin_D(MaxDim), PositionMax_D(MaxDim)

    ! Calculate normalized position of the edges of node inode.
    ! Zero is at the minimum boundary of the grid, one is at the max boundary

    integer :: iLevel
    integer :: MaxIndex_D(MaxDim)
    !------------------------------------------------------------------------
    iLevel = iTree_IA(Level_, iNode)

    MaxIndex_D = nRoot_D
    MaxIndex_D(1:nDimTree) = MaxCoord_I(iLevel)*MaxIndex_D(1:nDimTree)

    ! Convert to real by adding -1.0 or 0.0 for the two edges, respectively
    PositionMin_D = (iTree_IA(Coord1_:CoordLast_,iNode) - 1.0)/MaxIndex_D
    PositionMax_D = (iTree_IA(Coord1_:CoordLast_,iNode) + 0.0)/MaxIndex_D

  end subroutine get_tree_position

  !==========================================================================
  subroutine find_tree_node(CoordIn_D, iNode)

    ! Find the node that contains a point. The point coordinates should
    ! be given in generalized coordinates normalized to the domain size:
    ! CoordIn_D = (CoordOrig_D - CoordMin_D)/(CoordMax_D-CoordMin_D)

    real, intent(in):: CoordIn_D(MaxDim)
    integer, intent(out):: iNode

    real :: Coord_D(MaxDim)
    integer :: iLevel, iChild
    integer :: Ijk_D(MaxDim), iCoord_D(nDimTree), iBit_D(nDimTree)
    !----------------------------------------------------------------------
    ! Scale coordinates so that 1 <= Coord_D <= nRoot_D+1
    Coord_D = 1.0 + nRoot_D*max(0.0, min(1.0, CoordIn_D))

    ! Get root node index
    Ijk_D = min(int(Coord_D), nRoot_D)

    ! Root node indexes are ordered
    iNode = Ijk_D(1) + nRoot_D(1)*((Ijk_D(2)-1) + nRoot_D(2)*(Ijk_D(3)-1))

    if(iTree_IA(Status_, iNode) == Used_) RETURN

    ! Get normalized coordinates within root node and scale it up
    ! to the largest resolution
    iCoord_D = (Coord_D(1:nDimTree) - Ijk_D(1:nDimTree))*MaxCoord_I(nLevel)

    ! Go down the tree using bit information
    do iLevel = nLevel-1,0,-1
       iBit_D = ibits(iCoord_D, iLevel, 1)
       iChild = sum(iBit_D*MaxCoord_I(0:nDimTree-1)) + Child1_
       iNode = iTree_IA(iChild, iNode)

       if(iTree_IA(Status_, iNode) == Used_) RETURN
    end do


  end subroutine find_tree_node

  !==========================================================================
  logical function is_point_inside_node(Position_D, iNode)

    ! Check if position is inside node or not

    real,    intent(in):: Position_D(MaxDim)
    integer, intent(in):: iNode

    real    :: PositionMin_D(MaxDim), PositionMax_D(MaxDim)
    !-------------------------------------------------------------------------
    call get_tree_position(iNode, PositionMin_D, PositionMax_D)

    ! Include min edge but exclude max edge for sake of uniqueness
    is_point_inside_node = &
         all(Position_D >= PositionMin_D) .and. &
         all(Position_D <  PositionMax_D)

  end function is_point_inside_node

  !===========================================================================

  subroutine find_neighbors(iNode)

    integer, intent(in):: iNode

    integer :: iLevel, i, j, k, Di, Dj, Dk, jNode
    real :: Scale_D(MaxDim), x, y, z
    !-----------------------------------------------------------------------

    ! We should convert local node into global node index or vice-versa

    iLevel  = iTree_IA(Level_, iNode)
    Scale_D = (1.0/MaxCoord_I(iLevel))/nRoot_D
    do k=0,3
       Dk = nint((k - 1.5)/1.5)
       if(nDimTree < 3)then
          if(k/=1) CYCLE
          z = 0.3
       else
          z = (iTree_IA(CoordLast_, iNode) + 0.4*k - 1.1)*Scale_D(3)
          if(z > 1.0 .or. z < 0.0)then
             if(IsPeriodic_D(3))then
                z = modulo(z, 1.0)
             else
                iNodeNei_IIIB(:,:,k,iNode) = Unset_
                DiLevelNei_IIIB(:,:,Dk,iNode) = Unset_
                CYCLE
             end if
          end if
       end if
       do j=0,3
          Dj = nint((j - 1.5)/1.5)
          if(nDimTree < 2)then
             if(j/=1) CYCLE
             y = 0.3
          else
             y = (iTree_IA(Coord0_+2, iNode) + 0.4*j - 1.1)*Scale_D(2)
             if(y > 1.0 .or. y < 0.0)then
                if(IsPeriodic_D(2))then
                   y = modulo(y, 1.0)
                elseif(IsSpherical)then
                   ! Push back theta and go around half way in phi
                   y = max(0.0, min(1.0, y))
                   z = modulo( z+0.5, 1.0)
                else
                   iNodeNei_IIIB(:,j,k,iNode) = Unset_
                   DiLevelNei_IIIB(:,Dj,Dk,iNode) = Unset_
                   CYCLE
                end if
             end if
          end if
          do i=0,3
             ! Exclude inner points
             if(0<i.and.i<3.and.0<j.and.j<3.and.0<k.and.k<3) CYCLE

             Di = nint((i - 1.5)/1.5)

             ! If neighbor is not finer, fill in the i=2 or j=2 or k=2 elements
             if(DiLevelNei_IIIB(Di,Dj,Dk,iNode) >= 0)then
                if(i==2)then
                   iNodeNei_IIIB(i,j,k,iNode) = iNodeNei_IIIB(1,j,k,iNode)
                   CYCLE
                end if
                if(j==2)then
                   iNodeNei_IIIB(i,j,k,iNode) = iNodeNei_IIIB(i,1,k,iNode)
                   CYCLE
                end if
                if(k==2)then
                   iNodeNei_IIIB(i,j,k,iNode) = iNodeNei_IIIB(i,j,1,iNode)
                   CYCLE
                end if
             end if

             x = (iTree_IA(Coord1_, iNode) + 0.4*i - 1.1)*Scale_D(1)
             if(x > 1.0 .or. x < 0.0)then
                if(IsPeriodic_D(1))then
                   x = modulo(x, 1.0)
                elseif(IsCylindrical .and. x < 0.0)then
                   ! Push back radius and go around half way in phi direction
                   x = 0.0
                   z = modulo( z+0.5, 1.0)
                else
                   iNodeNei_IIIB(i,j,k,iNode) = Unset_
                   DiLevelNei_IIIB(Di,Dj,Dk,iNode) = Unset_
                   CYCLE
                end if
             end if

             call find_tree_node( (/x, y, z/), jNode)
             iNodeNei_IIIB(i,j,k,iNode) = jNode
             DiLevelNei_IIIB(Di,Dj,Dk,iNode) = &
                  iLevel - iTree_IA(Level_, jNode)
          end do
       end do
    end do

  end subroutine find_neighbors

  !==========================================================================

  subroutine compact_tree(nNodeAll)

    ! Eliminate holes from the tree

    integer, intent(out), optional:: nNodeAll

    ! Amount of shift for each node
    integer, allocatable:: iNodeNew_A(:)
    integer :: iNode, iNodeSkipped, iNodeOld, i
    !-------------------------------------------------------------------------
    allocate(iNodeNew_A(MaxNode))

    ! Set impossible initial values
    iNodeNew_A = Unset_
    iNodeSkipped = MaxNode + 1

    do iNode = 1, MaxNode

       if(iTree_IA(Status_, iNode) == Unset_)then
          ! Store the first skipped position
          iNodeSkipped = min(iNodeSkipped, iNode)
       elseif(iNodeSkipped < iNode)then
          ! Move node to the first skipped position
          iTree_IA(:,iNodeSkipped) = iTree_IA(:,iNode)
          iTree_IA(Status_, iNode) = Unset_
          ! Store new node index
          iNodeNew_A(iNode) = iNodeSkipped
          ! Advance iNodeSkipped
          iNodeSkipped = iNodeSkipped + 1
       else
          ! The node did not move
          iNodeNew_A(iNode) = iNode
       endif
    end do

    ! Apply shifts
    do iNode = 1, MaxNode

       if(iTree_IA(Status_, iNode) == Unset_) EXIT
       do i = Parent_, ChildLast_
          iNodeOld = iTree_IA(i, iNode)
          if(iNodeOld /= Unset_) &
               iTree_IA(i, iNode) = iNodeNew_A(iNodeOld)
       end do

    end do

    ! Fix the node indexes along the Peano curve
    do iPeano = 1, nNodeUsed
       iNodeOld = iNodePeano_I(iPeano)
       iNodePeano_I(iPeano) = iNodeNew_A(iNodeOld)
    end do

    if(present(nNodeAll)) nNodeAll = iNode - 1

  end subroutine compact_tree

  !==========================================================================

  subroutine write_tree_file(NameFile)

    use BATL_mpi, ONLY: iProc, barrier_mpi

    character(len=*), intent(in):: NameFile
    integer :: nNodeAll

    !-------------------------------------------------------------------------
    call compact_tree(nNodeAll)

    if(iProc == 0)then
       open(UnitTmp_, file=NameFile, status='replace', form='unformatted')

       write(UnitTmp_) nNodeAll, nInfo
       write(UnitTmp_) nDimTree, nRoot_D
       write(UnitTmp_) iTree_IA(:,1:nNodeAll)

       close(UnitTmp_)
    end if
    call barrier_mpi

  end subroutine write_tree_file
  
  !==========================================================================

  subroutine read_tree_file(NameFile)

    character(len=*), intent(in):: NameFile
    integer :: nInfoIn, nNodeIn, nDimTreeIn, nRootIn_D(MaxDim)
    character(len=*), parameter :: NameSub = 'read_tree_file'
    !----------------------------------------------------------------------

    open(UnitTmp_, file=NameFile, status='old', form='unformatted')

    read(UnitTmp_) nNodeIn, nInfoIn
    if(nNodeIn > MaxNode)then
       write(*,*) NameSub,' nNodeIn, MaxNode=',nNodeIn, MaxNode 
       call CON_stop(NameSub//' too many nodes in tree file!')
    end if
    read(UnitTmp_) nDimTreeIn, nRootIn_D
    if(nDimTreeIn /= nDimTree)then
       write(*,*) NameSub,' nDimTreeIn, nDimTree=',nDimTreeIn, nDimTree
       call CON_stop(NameSub//' nDimTree is different in tree file!')
    end if
    call set_tree_root(nRootIn_D, IsPeriodic_D)
    read(UnitTmp_) iTree_IA(:,1:nNodeIn)
    close(UnitTmp_)

    call order_tree

  end subroutine read_tree_file
  
  !==========================================================================
  subroutine distribute_tree(DoMove)

    ! Assign tree nodes to separate processors

    use BATL_mpi, ONLY: iProc, nProc

    ! Are nodes moved immediatly or just assigned new processor/node
    logical, intent(in):: DoMove

    integer :: nNodePerProc, iPeano, iNode, iBlockTo, iProcTo
    !------------------------------------------------------------------------

    ! Initialize processor and block indexes
    iTree_IA(ProcNew_:BlockNew_,:) = Unset_
    if(DoMove)then
       iTree_IA(Proc_:Block_,:) = Unset_
       Unused_B                 = .true.
    end if

    ! Create iNodePeano_I
    call order_tree

    ! An upper estimate on the number of nodes per processor
    nNodePerProc = (nNodeUsed-1)/nProc + 1

    do iPeano = 1, nNodeUsed
       iNode = iNodePeano_I(iPeano)

       iProcTo  = (iPeano-1)/nNodePerProc
       iBlockTo = modulo(iPeano-1, nNodePerProc) + 1

       ! Assign new processor and node
       iTree_IA(ProcNew_, iNode) = iProcTo
       iTree_IA(BlockNew_,iNode) = iBlockTo

       if(.not.DoMove) CYCLE

       ! Move the node to new processor/node
       iTree_IA(Proc_:Block_,iNode) = iTree_IA(ProcNew_:BlockNew_,iNode)
       iNode_BP(iBlockTo,iProcTo)   = iNode
       if(iProc == iProcTo) Unused_B(iBlockTo) = &
            iTree_IA(Status_,iNode) <= Unused_

    end do

    if(DoMove) nBlock = maxval(iTree_IA(Block_, :))

  end subroutine distribute_tree
  !==========================================================================

  subroutine order_tree

    ! Set iNodePeano_I indirect index array according to 
    ! 1. root node order
    ! 2. Morton ordering for each root node

    integer :: iNode, iRoot, jRoot, kRoot
    !-----------------------------------------------------------------------
    iNode = 0
    iPeano = 0
    iNodePeano_I = Unset_
    do kRoot = 1, nRoot_D(3)
       do jRoot = 1, nRoot_D(2)
          do iRoot = 1, nRoot_D(1)
             ! Root nodes are the first ones
             iNode = iNode + 1

             ! All root nodes are handled as if they were first child
             call order_children(iNode, Child1_)
          end do
       end do
    end do

    nNodeUsed = iPeano

  end subroutine order_tree
  !==========================================================================
  recursive subroutine order_children(iNode, iChildMe)

    integer, intent(in) :: iNode, iChildMe
    integer :: iChild
    !-----------------------------------------------------------------------
    if(iTree_IA(Status_, iNode) == Used_)then
       iPeano = iPeano + 1
       iNodePeano_I(iPeano) = iNode
    else
       do iChild = Child1_, ChildLast_
          ! iChild = iChildOrder_II(i, iChildMe)
          call order_children(iTree_IA(iChild, iNode), iChild)
       end do
    end if

  end subroutine order_children
  !==========================================================================

  subroutine show_tree(String)

    character(len=*), intent(in):: String

    character(len=10) :: Name
    character(len=200):: Header
    integer:: iInfo, iNode
    !-----------------------------------------------------------------------
    Header = 'iNode'
    do iInfo = 1, nInfo
       Name = NameTreeInfo_I(iInfo)
       Header(7*iInfo+1:7*(iInfo+1)-1) = Name(1:6)
    end do

    write(*,*) String
    write(*,*) trim(Header)
    do iNode = 1, MaxNode
       if(iTree_IA(Status_, iNode) == Unset_) CYCLE
       write(*,'(100i7)') iNode, iTree_IA(:, iNode)
    end do

  end subroutine show_tree
  !==========================================================================

  subroutine test_tree

    use BATL_mpi, ONLY: iProc

    integer :: iNode, nNodeAll, Int_D(MaxDim)
    real:: CoordTest_D(MaxDim)

    logical :: DoTestMe
 
    character(len=*), parameter :: NameSub = 'test_tree'
    !-----------------------------------------------------------------------

    DoTestMe = iProc == 0

    if(DoTestMe)write(*,*)'Testing init_tree'
    call init_tree(50, 100)
    if(MaxBlock /= 50) &
         write(*,*)'init_mod_octtree faild, MaxBlock=',&
         MaxBlock, ' should be 50'

    if(MaxNode /= 100) &
         write(*,*)'init_mod_octtree faild, MaxNode=',&
         MaxNode, ' should be 100'

    if(DoTestMe)write(*,*)'Testing i_node_new()'
    iNode = i_node_new()
    if(iNode /= 1) &
         write(*,*)'i_node_new() failed, iNode=',iNode,' should be 1'

    if(DoTestMe)write(*,*)'Testing set_tree_root'
    call set_tree_root( (/1,2,3/), (/.true., .true., .false./) )

    if(DoTestMe)call show_tree('after set_tree_root')

    if(any( nRoot_D /= (/1,2,3/) )) &
         write(*,*) 'set_tree_root failed, nRoot_D=',nRoot_D,&
         ' should be 1,2,3'

    Int_D = (/1,2,2/)

    if(any( iTree_IA(Coord1_:CoordLast_,4) /= Int_D )) &
         write(*,*) 'set_tree_root failed, coordinates of node four=',&
         iTree_IA(Coord1_:CoordLast_,4), ' should be ',Int_D(1:nDimTree)

    if(DoTestMe)write(*,*)'Testing find_tree_node'
    CoordTest_D = (/0.99,0.99,0.9/)
    call find_tree_node(CoordTest_D, iNode)
    if(iNode /= nRoot)write(*,*)'ERROR: Test find point failed, iNode=',&
         iNode,' instead of',nRoot

    if(.not.is_point_inside_node(CoordTest_D, iNode)) &
         write(*,*)'ERROR: Test find point failed'
    
    if(DoTestMe)write(*,*)'Testing refine_tree_node'
    ! Refine the node where the point was found and find it again
    call refine_tree_node(iNode)

    if(DoTestMe)call show_tree('after refine_tree_node')

    call find_tree_node(CoordTest_D,iNode)
    if(.not.is_point_inside_node(CoordTest_D, iNode)) &
         write(*,*)'ERROR: Test find point failed for iNode=',iNode

    ! Refine another node
    if(DoTestMe)write(*,*)'nRoot=',nRoot
    call refine_tree_node(nRoot-2)

    if(DoTestMe)call show_tree('after another refine_tree_node')

    if(DoTestMe)write(*,*)'Testing find_neighbors'
    call find_neighbors(5)
    if(DoTestMe)write(*,*)'DiLevelNei_IIIB(:,:,:,5)=', DiLevelNei_IIIB(:,:,:,5)
    if(DoTestMe)write(*,*)'iNodeNei_IIIB(:,:,:,5)=', iNodeNei_IIIB(:,:,:,5)

    if(DoTestMe)write(*,*)'Testing distribute_tree 1st'
    call distribute_tree(.false.)
    if(DoTestMe)write(*,*)'iNodePeano_I =', iNodePeano_I(1:22)
    if(DoTestMe)call show_tree('after distribute_tree 1st')

    if(DoTestMe)write(*,*)'Testing coarsen_tree_node'

    ! Coarsen back the last root node and find point again
    call coarsen_tree_node(nRoot)
    if(DoTestMe)call show_tree('after coarsen_tree_node')

    call find_tree_node(CoordTest_D,iNode)
    if(iNode /= nRoot)write(*,*)'ERROR: coarsen_tree_node faild, iNode=',&
         iNode,' instead of',nRoot
    if(.not.is_point_inside_node(CoordTest_D, iNode)) &
         write(*,*)'ERROR: is_point_inside_node failed'


    if(DoTestMe)write(*,*)'Testing distribute_tree 2nd'
    call distribute_tree(.true.)
    if(DoTestMe)write(*,*)'iNodePeano_I =',iNodePeano_I(1:22)

    if(DoTestMe)write(*,*)'Testing compact_tree'
    call compact_tree(nNodeAll)
    if(DoTestMe)call show_tree('after compact_tree')

    if(iTree_IA(Status_, nNodeAll+1) /= Unset_) &
         write(*,*)'ERROR: compact_tree faild, nNodeAll=', nNodeAll, &
         ' but status of next node is', iTree_IA(Status_, nNodeAll+1), &
         ' instead of ',Unset_
    if(any(iTree_IA(Status_, 1:nNodeAll) == Unset_)) &
         write(*,*)'ERROR: compact_tree faild, nNodeAll=', nNodeAll, &
         ' but iTree_IA(Status_, 1:nNodeAll)=', &
         iTree_IA(Status_, 1:nNodeAll),' contains unset=',Unset_
    call find_tree_node(CoordTest_D,iNode)
    if(iNode /= nRoot)write(*,*)'ERROR: compact_tree faild, iNode=',&
         iNode,' instead of',nRoot
    if(.not.is_point_inside_node(CoordTest_D, iNode)) &
         write(*,*)'ERROR: is_point_inside_node failed'

    if(DoTestMe)write(*,*)'Testing distribute_tree 3rd'
    call distribute_tree(.true.)
    if(DoTestMe)write(*,*)'iNodePeano_I =',iNodePeano_I(1:22)

    if(DoTestMe)write(*,*)'Testing write_tree_file'
    call write_tree_file('tree.rst')

    if(DoTestMe)write(*,*)'Testing read_tree_file'
    iTree_IA = Unset_
    nRoot_D = 0
    call read_tree_file('tree.rst')
    if(DoTestMe)call show_tree('after read_tree')

    call find_tree_node(CoordTest_D,iNode)
    if(iNode /= nRoot)write(*,*)'ERROR: compact_tree faild, iNode=',&
         iNode,' instead of',nRoot

    if(DoTestMe)write(*,*)'Testing distribute_tree 4th'
    call distribute_tree(.true.)
    if(DoTestMe)write(*,*)'iNodePeano_I =',iNodePeano_I(1:22)

    if(DoTestMe)write(*,*)'Testing clean_tree'
    call clean_tree
    if(DoTestMe)write(*,*)'MaxNode=', MaxNode

  end subroutine test_tree

end module BATL_tree
