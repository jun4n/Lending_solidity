// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

/*
ETH를 담보로 사용해서 USDC를 빌리고 빌려줄 수 있는 서비스를 구현하세요.
이자율은 24시간에 0.1% (복리), Loan To Value (LTV)는 50% => 1ETH담보로 0.5ETH 만큼의 usdc
, liquidation threshold => 청산 임계값 는 75%로 하고 담보 가격 정보는 “참고코드"를 참고해 생성한 컨트랙트에서 갖고 오세요.
필요한 기능들은 다음과 같습니다. Deposit (ETH, USDC 입금), Borrow (담보만큼 USDC 대출), Repay (대출 상환), Liquidate (담보를 청산하여 USDC 확보)
청산 방법은 다양하기 때문에 조사 후 bad debt을 최소화에 가장 적합하다고 생각하는 방식을 적용하고 그 이유를 쓰세요.
실제 토큰을 사용하지 않고 컨트랙트 생성자의 인자로 받은 주소들을 토큰의 주소로 간주합니다.
주요 기능 인터페이스는 아래를 참고해 만드시면 됩니다.
 */
 import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
 import "forge-std/console.sol";
 contract IPriceOracle {
   address public operator;
   mapping(address=>uint256) prices;

   constructor() {
       operator = msg.sender;
   }
   function getPrice(address token) external view returns (uint256) {
       require(prices[token] != 0, "the price cannot be zero");
       return prices[token];
   }
   function setPrice(address token, uint256 price) external {
       require(msg.sender == operator, "only operator can set the price");
       prices[token] = price;
   }
}


contract DreamAcademyLending {
    IPriceOracle oracle;
    address _usdc;
    address _eth;
    mapping(address => uint) deposit_usdc;
    mapping(address => uint) deposit_eth;
    mapping(address => uint) borrow_usdc;
    mapping(address => uint) borrow_eth;
    mapping(address => uint) collateral_usdc;
    mapping(address => uint) collateral_eth;
    uint pool_deposit_usdc;

    constructor (IPriceOracle _oracle, address usdc){
        oracle = _oracle;
        _usdc = usdc;
    }

    function initializeLendingProtocol(address usdc) public payable {
        ERC20(usdc).transferFrom(msg.sender, address(this), msg.value);
        deposit_eth[msg.sender] += msg.value;
        deposit_usdc[msg.sender] += msg.value;
    }

    function deposit(address tokenAddress, uint256 amount) external payable{
        if (tokenAddress == _eth){
            //require(msg.value > 0, "must deposit more than 0 ether");
            require(msg.value == amount, "insufficient eth");
            deposit_eth[msg.sender] += msg.value;
        }else{
            require(ERC20(tokenAddress).allowance(msg.sender, address(this)) >= amount, "insufficient usdc");
            deposit_usdc[msg.sender] += amount;
            ERC20(tokenAddress).transferFrom(msg.sender, address(this), amount);
            pool_deposit_usdc = ERC20(tokenAddress).balanceOf(address(this));
        }
    }

    // tokenAddress를 amount만큼 빌리고 싶다
    function borrow(address tokenAddress, uint256 amount) external{
        uint current_usdc = oracle.getPrice(_usdc);
        uint current_eth = oracle.getPrice(_eth);
        uint avaliable_amount;
        if(tokenAddress == _usdc){
            avaliable_amount =  (deposit_eth[msg.sender] * current_eth / current_usdc) /  2;
            require(avaliable_amount >= amount, "need more deposit");
            require(avaliable_amount <= ERC20(_usdc).balanceOf(address(this)), "we don't have that much zz");
            
            uint collateral = amount * current_usdc / current_eth * 2;
            borrow_usdc[msg.sender] += amount;
            collateral_eth[msg.sender] += collateral;
            deposit_eth[msg.sender] -= collateral;

            ERC20(tokenAddress).transfer(msg.sender, amount);
        }else{
            avaliable_amount =  (deposit_usdc[msg.sender] * current_usdc / current_eth) /  2;
            require(avaliable_amount >= amount, "need more deposit");
            require(avaliable_amount <= address(this).balance, "we don't have that much zz");
            
            uint collateral = amount * current_eth / current_usdc * 2;
            borrow_eth[msg.sender] += amount;
            collateral_usdc[msg.sender] += collateral;
            deposit_usdc[msg.sender] -= collateral;

            (bool success, ) = msg.sender.call{value: amount}("");
            require(success);
        }
    }
    function repay(address tokenAddress, uint256 amount) external{

    }
    function liquidate(address user, address tokenAddress, uint256 amount) external{

    }
    function withdraw(address tokenAddress, uint256 amount) external{

    }
    function getAccruedSupplyAmount(address token) public returns(uint){

    }

}